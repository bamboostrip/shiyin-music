import 'dart:collection';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../core/folder_filter.dart';
import '../models/music_models.dart';

class LocalMusicController extends ChangeNotifier {
  LocalMusicController() {
    _init();
  }

  static const _channel = MethodChannel('kgka_music_hl/local_music');
  static const _excludedFoldersKey = 'settings.local_music_excluded_folders';

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
  final _albumArtCache = LinkedHashMap<String, Uint8List>();

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
          final title = item['title'] as String? ?? '未知歌曲';
          final artist = item['artist'] as String? ?? '未知艺人';
          final durationMs = item['duration'] as int?;

          if (filePath.isNotEmpty) {
            list.add(
              Song(
                id: filePath,
                title: title,
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
}
