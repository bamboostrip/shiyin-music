import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../core/folder_filter.dart';
import '../models/music_models.dart';
import '../src/rust/api.dart' as rust;
import '../src/rust/services/local_media.dart' show LocalSongEntry;

class LocalMusicController extends ChangeNotifier {
  LocalMusicController() {
    _init();
  }

  static const _channel = MethodChannel('kgka_music_hl/local_music');
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

  // 本地专辑封面字节缓存上限（LRU，按插入顺序淘汰最早项）。
  // 50 → 100：封面为压缩字节（常见 500×500 JPEG ≈ 50-200KB），
  // 100 张 ≈ 5-20MB，换取滚动本地歌曲列表时更少触发原生
  // content provider 查询（该查询较慢，是列表滚动的卡顿来源之一）。
  static const _maxAlbumArtCacheSize = 100;
  final _albumArtCache = <String, Uint8List>{};

  /// 规范化文件夹路径 -> 原始大小写路径（仅用于界面展示）。
  final Map<String, String> _folderDisplayNames = {};

  bool get hasPermission => _hasPermission;
  List<Song> get songs => _songs;
  bool get isScanning => _isScanning;

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

    _isScanning = true;
    notifyListeners();

    try {
      final List<dynamic> result = await _channel.invokeMethod('getLocalSongs');
      final List<Song> list = [];

      for (final item in result) {
        if (item is Map) {
          final filePath = item['filePath'] as String? ?? '';
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
                coverUrl: item['albumArtUri'] as String?,
                duration: durationMs != null
                    ? Duration(milliseconds: durationMs)
                    : null,
                source: SongSource.local,
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

  /// 获取本地歌曲的专辑封面字节数据（带缓存）。
  Future<Uint8List?> getAlbumArt(String albumId) async {
    if (!Platform.isAndroid) return null;
    if (_albumArtCache.containsKey(albumId)) {
      return _albumArtCache[albumId];
    }
    try {
      final bytes = await _channel.invokeMethod<Uint8List>('getAlbumArt', {
        'albumId': int.tryParse(albumId),
      });
      if (bytes != null) {
        _albumArtCache[albumId] = bytes;
        if (_albumArtCache.length > _maxAlbumArtCacheSize) {
          _albumArtCache.remove(_albumArtCache.keys.first);
        }
      }
      return bytes;
    } catch (e) {
      debugPrint('Error getting album art: $e');
      return null;
    }
  }

  /// 获取本地歌曲的内嵌歌词。
  Future<String?> getEmbeddedLyrics(String filePath) async {
    if (isDesktopScanSupported) {
      try {
        return await rust.readLocalLyrics(path: filePath);
      } catch (e) {
        debugPrint('Error reading embedded lyrics (rust): $e');
        return null;
      }
    }
    if (!Platform.isAndroid) return null;
    try {
      return await _channel.invokeMethod<String>('getEmbeddedLyrics', {
        'filePath': filePath,
      });
    } catch (e) {
      debugPrint('Error getting embedded lyrics: $e');
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
    await scanLocalMusic();
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
    await scanLocalMusic();
  }

  /// Rust 引擎扫描：递归列出根目录下音频文件并 probe 标签/时长。
  /// 进度（done/total）驱动 UI；结果/失败经流事件（见 rust/src/api.rs
  /// 的 ScanEvent，frb 的 StreamSink 模式不保留返回值）。
  Future<void> _scanDesktopMusic() async {
    if (!isDesktopScanSupported) return;
    if (_desktopRoots.isEmpty) return;
    if (_isScanning) return;

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
    notifyListeners();
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
      coverUrl: null,
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
}
