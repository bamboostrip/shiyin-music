import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../core/folder_filter.dart';
import '../models/music_models.dart';
import '../src/rust/api.dart' as rust;
import '../src/rust/services/local_media.dart' show LocalSongEntry;
import '../services/local_artwork_service.dart';

class LocalMusicController extends ChangeNotifier {
  LocalMusicController({
    Future<String?> Function(String path)? rustLyricsReader,
    Future<String?> Function(Uint8List bytes)? rustLyricsBytesReader,
    Future<Uint8List?> Function(String source)? mediaHeadReader,
  })  : _rustLyricsReader = rustLyricsReader ?? _defaultRustLyricsReader,
        _rustLyricsBytesReader =
            rustLyricsBytesReader ?? _defaultRustLyricsBytesReader,
        _mediaHeadReader = mediaHeadReader ?? _defaultMediaHeadReader {
    _init();
  }

  /// 三个读取器抽成可注入字段：单测里 Rust 引擎与平台通道都跑不起来，
  /// 注入假实现才能钉住回退顺序（默认实现见文件底部静态函数）。
  final Future<String?> Function(String path) _rustLyricsReader;
  final Future<String?> Function(Uint8List bytes) _rustLyricsBytesReader;
  final Future<Uint8List?> Function(String source) _mediaHeadReader;

  @override
  void dispose() {
    _disposed = true;
    // 扫描在途时销毁控制器：不取消的话，后续扫描事件回调仍会
    // _applyFolderFilter() → notifyListeners()（对已 dispose 的
    // ChangeNotifier，debug 构建抛错）。
    unawaited(_scanSubscription?.cancel());
    _scanSubscription = null;
    super.dispose();
  }

  static const _channel = MethodChannel('shiyin_music/local_music');
  static const _excludedFoldersKey = 'settings.local_music_excluded_folders';

  // ---- 桌面（Windows/Linux）扫描根目录 ----
  // Android 走 MediaStore 全盘扫描；桌面没有统一媒体库，用户显式添加
  // 根目录后由 Rust 引擎（symphonia probe）递归扫描并读标签。
  static const _desktopRootsKey = 'local_music.desktop_roots';

  /// 桌面是否支持本地音乐扫描（Rust 引擎仅接入 Windows/Linux 构建）。
  static bool get isDesktopScanSupported =>
      !kIsWeb && (Platform.isWindows || Platform.isLinux);

  List<String> _desktopRoots = [];
  StreamSubscription<rust.ScanEvent>? _scanSubscription;
  int _scanDone = 0;
  int _scanTotal = 0;

  /// 用户添加的桌面扫描根目录（原样保存，展示用）。
  List<String> get desktopRoots => List.unmodifiable(_desktopRoots);

  /// 桌面扫描进度（已处理 / 总数），仅 [isScanning] 时有意义。
  ({int done, int total}) get scanProgress => (done: _scanDone, total: _scanTotal);

  bool _hasPermission = false;
  List<Song> _songs = [];
  List<Song> _rawSongs = [];
  final Set<String> _excludedFolders = {};
  bool _isScanning = false;
  /// 扫描进行中收到根目录增删触发的重扫请求：收尾时补跑一次，避免变更被静默丢弃。
  bool _rescanPending = false;
  // dispose 后丢弃在途扫描结果/通知：_checkPermission / scanLocalMusic /
  // _scanDesktopMusic 都有长 await（平台通道、最长 10 分钟的 Rust 扫描），
  // 恢复执行时若仍 notifyListeners，对已 dispose 的 ChangeNotifier 在
  // debug 构建抛错（与 DownloadController._disposed 同款防护）。
  bool _disposed = false;

  /// 规范化文件夹路径 -> 原始大小写路径（仅用于界面展示）。
  final Map<String, String> _folderDisplayNames = {};

  bool get hasPermission => _hasPermission;
  List<Song> get songs => _songs;
  bool get isScanning => _isScanning;

  /// 按裸路径查这首歌在媒体库里的 `content://` 地址。
  ///
  /// 用途：升级前落盘的队列/历史条目没有 [Song.localContentUri]（老版本
  /// 不序列化该字段），Android 10 上裸路径不可读时靠这里从当前库状态兜底
  /// （issue #32：自动重扫完成后，第二次尝试即可命中）。
  String? contentUriForPath(String path) {
    for (final song in _songs) {
      if (song.id == path) return song.localContentUri;
    }
    return null;
  }

  /// 已排除的文件夹列表（规范化后的绝对路径）。
  Set<String> get excludedFolders => Set.unmodifiable(_excludedFolders);

  /// 扫描到的全部音频所在文件夹及歌曲数量（未应用排除规则），
  /// 供「扫描目录设置」界面展示与勾选。
  List<({String folder, int count})> get availableFolders {
    return [
      for (final entry in FolderFilter.folderCounts(_rawSongs))
        (
          folder: _folderDisplayNames[entry.folder] ?? entry.folder,
          count: entry.count,
        ),
    ];
  }

  bool isFolderExcluded(String folder) {
    final normalized = FolderFilter.normalizeFolderPath(folder);
    return normalized != null && _excludedFolders.contains(normalized);
  }

  Future<void> _init() async {
    await _loadExcludedFolders();
    if (isDesktopScanSupported) {
      await _loadDesktopRoots();
      if (_desktopRoots.isNotEmpty) {
        unawaited(scanLocalMusic());
      }
      return;
    }
    await _checkPermission();
  }

  Future<void> _loadExcludedFolders() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getStringList(_excludedFoldersKey) ?? const [];
      _excludedFolders
        ..clear()
        ..addAll(
          stored.map(FolderFilter.normalizeFolderPath).whereType<String>(),
        );
    } catch (e) {
      debugPrint('Error loading excluded folders: $e');
    }
  }

  Future<void> _persistExcludedFolders() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_excludedFoldersKey, _excludedFolders.toList());
    } catch (e) {
      debugPrint('Error persisting excluded folders: $e');
    }
  }

  /// 设置某个文件夹是否被排除。返回后本地音乐列表会即时更新。
  Future<void> setFolderExcluded(String folder, bool excluded) async {
    final normalized = FolderFilter.normalizeFolderPath(folder);
    if (normalized == null) return;
    final changed = excluded
        ? _excludedFolders.add(normalized)
        : _excludedFolders.remove(normalized);
    if (!changed) return;
    _applyFolderFilter();
    notifyListeners();
    await _persistExcludedFolders();
  }

  /// 清空全部排除规则，恢复扫描所有目录。
  Future<void> clearExcludedFolders() async {
    if (_excludedFolders.isEmpty) return;
    _excludedFolders.clear();
    _applyFolderFilter();
    notifyListeners();
    await _persistExcludedFolders();
  }

  /// 应用排除规则：从原始扫描结果生成展示列表。
  void _applyFolderFilter() {
    _songs = FolderFilter.filterSongs(_rawSongs, _excludedFolders);
  }

  Future<void> _checkPermission() async {
    if (!Platform.isAndroid) return;
    try {
      final granted =
          await _channel.invokeMethod<bool>('hasPermission') ?? false;
      if (_disposed) return;
      _hasPermission = granted;
      notifyListeners();
      if (_hasPermission) {
        await scanLocalMusic();
      }
    } catch (e) {
      debugPrint('Error checking audio permission: $e');
    }
  }

  Future<bool> requestPermission() async {
    if (!Platform.isAndroid) return false;
    try {
      final granted =
          await _channel.invokeMethod<bool>('requestPermission') ?? false;
      if (_disposed) return granted;
      _hasPermission = granted;
      notifyListeners();
      if (_hasPermission) {
        await scanLocalMusic();
      }
      return granted;
    } catch (e) {
      debugPrint('Error requesting audio permission: $e');
      return false;
    }
  }

  Future<void> scanLocalMusic() async {
    if (isDesktopScanSupported) {
      await _scanDesktopMusic();
      return;
    }
    if (!Platform.isAndroid) return;
    if (!_hasPermission) return;

    // 重入保护：手动扫描进行中时，自动重扫（文件缺失触发）直接跳过——
    // 并发扫只是重复查询、last-wins，桌面路径同款守卫。
    if (_isScanning) return;

    _isScanning = true;
    notifyListeners();

    try {
      final List<dynamic> result = await _channel.invokeMethod('getLocalSongs');
      final List<Song> list = [];

      for (final item in result) {
        if (item is Map) {
          final filePath = item['filePath'] as String? ?? '';
          final contentUri = item['contentUri'] as String? ?? '';
          final rawTitle = item['title'] as String? ?? '未知歌曲';
          final artist = item['artist'] as String? ?? '未知艺人';
          final durationMs = item['duration'] as int?;
          final cleanedTitle = cleanSongTitle(rawTitle, artist: artist);

          if (filePath.isNotEmpty) {
            list.add(
              Song(
                id: filePath,
                title: cleanedTitle,
                rawTitle: rawTitle,
                artist: artist,
                hash: filePath,
                // 封面走「文件内嵌图」而不是 MediaStore 的 albumArtUri：
                // 后者的 provider URI 自 Android 10 起已被移除，取图必失败
                // （issue #32 的「本地文件加载不出封面」）。
                // 优先用 content:// 当读取目标：分区存储下裸路径不一定可读
                // （Android 10 直接拒绝），content URI 在所有版本都能读。
                coverUrl: LocalArtworkService.artworkUrlFor(
                  contentUri.isNotEmpty ? contentUri : filePath,
                ),
                duration: durationMs != null
                    ? Duration(milliseconds: durationMs)
                    : null,
                source: SongSource.local,
                localContentUri: contentUri.isEmpty ? null : contentUri,
              ),
            );
            _recordFolderDisplayName(filePath);
          }
        }
      }

      _rawSongs = list;
      _applyFolderFilter();
    } catch (e) {
      debugPrint('Error scanning local music: $e');
    }

    if (_disposed) return;
    _isScanning = false;
    notifyListeners();
  }

  /// 记录文件父目录的原始大小写显示名（规范化路径作 key）。
  void _recordFolderDisplayName(String filePath) {
    final normalizedPath = filePath.trim().replaceAll('\\', '/');
    final index = normalizedPath.lastIndexOf('/');
    if (index <= 0) return;
    final rawParent = normalizedPath.substring(0, index);
    final normalized = FolderFilter.normalizeFolderPath(rawParent);
    if (normalized != null) {
      _folderDisplayNames.putIfAbsent(normalized, () => rawParent);
    }
  }

  /// 获取本地歌曲的内嵌歌词。
  ///
  /// 读取顺序（issue #32 的 Android 10 兜底）：
  /// 1. Rust 按裸路径读（Android 11+ / 桌面正常路径）；
  /// 2. 路径打不开（Err）且带 [contentUri] 时（Android 10 分区存储）：
  ///    经通道截取文件头部字节 → Rust 字节解析（ID3v2 驻留文件头，截断数据
  ///    里完整可用；容器层尽力而为）。
  /// 「路径解析成功但没有歌词」（Ok(None)）是确定性结论，不再兜底。
  ///
  /// 注：`MediaMetadataRetriever` 没有歌词 metadata key（历史上的
  /// extractMetadata(26) 实为 METADATA_KEY_HAS_IMAGE），移动端内嵌歌词
  /// 从未生效过——这是统一走 Rust 的原因。
  Future<String?> getEmbeddedLyrics(String filePath, {String? contentUri}) async {
    try {
      return await _rustLyricsReader(filePath);
    } catch (e) {
      debugPrint('按路径读内嵌歌词失败，准备走头部字节兜底: $filePath ($e)');
    }
    if (contentUri == null || contentUri.isEmpty) return null;
    try {
      final head = await _mediaHeadReader(contentUri);
      if (head == null || head.isEmpty) return null;
      return await _rustLyricsBytesReader(head);
    } catch (e) {
      debugPrint('头部字节兜底读内嵌歌词失败: $contentUri ($e)');
      return null;
    }
  }

  // ---- 桌面（Windows/Linux）本地音乐 ----

  Future<void> _loadDesktopRoots() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _desktopRoots =
          (prefs.getStringList(_desktopRootsKey) ?? const []).toList();
    } catch (e) {
      debugPrint('Error loading desktop roots: $e');
    }
  }

  Future<void> _persistDesktopRoots() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_desktopRootsKey, _desktopRoots);
    } catch (e) {
      debugPrint('Error persisting desktop roots: $e');
    }
  }

  /// 添加桌面扫描根目录（去重后持久化并立即重新扫描）。
  Future<void> addDesktopRoot(String path) async {
    final normalized = path.trim();
    if (normalized.isEmpty || _desktopRoots.contains(normalized)) return;
    _desktopRoots.add(normalized);
    notifyListeners();
    await _persistDesktopRoots();
    await _scanAfterRootChange();
  }

  /// 移除桌面扫描根目录并重新扫描（歌曲列表即时收敛）。
  Future<void> removeDesktopRoot(String path) async {
    if (!_desktopRoots.remove(path)) return;
    notifyListeners();
    await _persistDesktopRoots();
    if (_desktopRoots.isEmpty) {
      _rawSongs = [];
      _applyFolderFilter();
      notifyListeners();
      return;
    }
    await _scanAfterRootChange();
  }

  /// 根目录增删后触发重扫：若扫描正在进行（_scanDesktopMusic 会直接 no-op），
  /// 标记待办，由扫描收尾补跑一次，保证变更不被静默丢弃。
  Future<void> _scanAfterRootChange() async {
    if (_isScanning) {
      _rescanPending = true;
      return;
    }
    await scanLocalMusic();
  }

  /// Rust 引擎扫描：递归列出根目录下音频文件并 probe 标签/时长。
  /// 进度（done/total）驱动 UI；结果/失败经流事件（见 rust/src/api.rs
  /// 的 ScanEvent，frb 的 StreamSink 模式不保留返回值）。
  Future<void> _scanDesktopMusic() async {
    if (!isDesktopScanSupported) return;
    if (_desktopRoots.isEmpty) return;
    if (_isScanning) return;
    if (_disposed) return;

    _isScanning = true;
    _scanDone = 0;
    _scanTotal = 0;
    notifyListeners();

    try {
      final stream = rust.scanLocalMedia(roots: _desktopRoots.toList());
      _scanSubscription?.cancel();
      final completer = Completer<void>();
      _scanSubscription = stream.listen(
        (event) {
          if (_disposed) return;
          final failure = event.failure;
          if (failure != null) {
            debugPrint('LocalMusicController: 桌面扫描失败: $failure');
            return;
          }
          final entries = event.entries;
          if (entries != null) {
            _rawSongs = [
              for (final entry in entries) _songFromDesktopEntry(entry),
            ];
            for (final song in _rawSongs) {
              _recordFolderDisplayName(song.id);
            }
            _applyFolderFilter();
            return;
          }
          _scanDone = event.done;
          _scanTotal = event.total;
          notifyListeners();
        },
        onError: (Object error) {
          debugPrint('LocalMusicController: 桌面扫描异常: $error');
        },
        onDone: () {
          if (!completer.isCompleted) completer.complete();
        },
        cancelOnError: false,
      );
      await completer.future.timeout(const Duration(minutes: 10), onTimeout: () {
        unawaited(rust.cancelLocalScan());
      });
    } catch (e) {
      debugPrint('Error scanning desktop local music: $e');
    }

    await _scanSubscription?.cancel();
    _scanSubscription = null;
    _isScanning = false;
    if (_disposed) return;
    notifyListeners();

    // 扫描期间根目录发生过增删：补跑一次，收敛到最新根目录集合
    // （单次补跑即可，补跑中若再有变更会再次标记，不会无限递归）。
    if (_rescanPending) {
      _rescanPending = false;
      await _scanDesktopMusic();
    }
  }

  /// Rust 扫描条目 → Song。标签缺失回退"文件名猜标题"
  /// （"艺术家 - 歌名.ext" 模式由 cleanSongTitle 解析）。
  Song _songFromDesktopEntry(LocalSongEntry entry) {
    final fileName = _fileNameOf(entry.path);
    final rawTitle = entry.title.isNotEmpty ? entry.title : fileName;
    final artist = entry.artist.isNotEmpty ? entry.artist : '未知艺人';
    final cleanedTitle = cleanSongTitle(rawTitle, artist: artist);
    return Song(
      id: entry.path,
      title: cleanedTitle,
      rawTitle: rawTitle,
      artist: artist,
      albumName: entry.album.isNotEmpty ? entry.album : null,
      hash: entry.path,
      // 桌面端此前恒为 null（Rust 扫描只读标签不取图），本地歌永远只有
      // 音符占位。改为按需读内嵌封面（Rust symphonia visuals）。
      coverUrl: LocalArtworkService.artworkUrlFor(entry.path),
      duration: entry.durationMs > 0
          ? Duration(milliseconds: entry.durationMs.toInt())
          : null,
      source: SongSource.local,
    );
  }

  /// 路径 → 去扩展名的文件名（标题回退用）。
  static String _fileNameOf(String path) {
    final normalized = path.replaceAll('\\', '/');
    final name = normalized.substring(normalized.lastIndexOf('/') + 1);
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  /// 默认路径读取器：Rust 按裸路径读内嵌歌词（Err 时 throw，由
  /// [getEmbeddedLyrics] 捕获后走兜底）。
  static Future<String?> _defaultRustLyricsReader(String path) =>
      rust.readLocalLyrics(path: path);

  /// 默认字节读取器：Rust 从头部字节解析内嵌歌词（任何「读不了」
  /// 都返回 null，不抛错）。
  static Future<String?> _defaultRustLyricsBytesReader(Uint8List bytes) =>
      rust.readLocalLyricsFromBytes(data: bytes);

  /// 默认头部截取器：经平台通道读文件头部字节（Android 10 分区存储下
  /// 裸路径不可读，content:// 只有 ContentResolver 认识）。
  static Future<Uint8List?> _defaultMediaHeadReader(String source) =>
      _channel.invokeMethod<Uint8List>('readMediaHead', {'source': source});
}
