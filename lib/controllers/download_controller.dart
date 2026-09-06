import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/music_models.dart';
import '../services/desktop_system_integration.dart';
import '../services/download_service.dart';
import '../services/music_api.dart';

/// 下载状态枚举。
enum DownloadStatus { notDownloaded, downloading, downloaded, failed }

/// 批量下载结果统计。
class BatchDownloadResult {
  const BatchDownloadResult({
    required this.enqueued,
    required this.skipped,
    required this.failed,
  });

  /// 成功加入下载队列的歌曲数。
  final int enqueued;

  /// 跳过的歌曲数（已下载或已在下载中）。
  final int skipped;

  /// 加入队列失败（无播放地址/网络错误）的歌曲数。
  final int failed;

  /// 已加入队列（含已下载与失败）的总处理数量。
  int get total => enqueued + skipped + failed;
}

/// 下载条目。
class DownloadEntry {
  const DownloadEntry({
    required this.song,
    required this.quality,
    required this.status,
    this.progress = 0,
    this.filePath,
    this.error,
    this.downloadedAt,
  });

  final Song song;
  final AudioQuality quality;
  final DownloadStatus status;
  final double progress;
  final String? filePath;
  final String? error;
  final DateTime? downloadedAt;

  DownloadEntry copyWith({
    DownloadStatus? status,
    double? progress,
    String? filePath,
    String? error,
    DateTime? downloadedAt,
  }) {
    return DownloadEntry(
      song: song,
      quality: quality,
      status: status ?? this.status,
      progress: progress ?? this.progress,
      filePath: filePath ?? this.filePath,
      error: error,
      downloadedAt: downloadedAt ?? this.downloadedAt,
    );
  }
}

/// 播放缓存条目。
class PlayCacheEntry {
  const PlayCacheEntry({
    required this.cacheKey,
    required this.song,
    required this.quality,
    required this.filePath,
    required this.size,
    required this.cachedAt,
  });

  final String cacheKey;
  final Song song;
  final AudioQuality quality;
  final String filePath;
  final int size;
  final DateTime cachedAt;
}

/// 下载与播放缓存控制器。
///
/// 管理用户主动下载（持久目录）和播放缓存（临时目录）。
/// 下载状态通过 [DownloadStatus] + [entryFor] 查询，UI 用 AnimatedBuilder 监听。
class DownloadController extends ChangeNotifier {
  DownloadController(this._service, this._api);

  final DownloadService _service;
  final MusicApi _api;

  static const _downloadsIndexKey = 'ka_music_downloads_index';
  static const _playCacheIndexKey = 'ka_music_play_cache_index';
  static const _playCacheLimitKey = 'settings.play_cache_limit';

  final Map<String, DownloadEntry> _downloads = {}; // key = hash
  final Map<String, PlayCacheEntry> _playCache = {}; // key = hash_quality
  // 同曲索引：hash -> cacheKey 集合，避免 AnyQuality 查询时 O(n) 全表
  // 扫描 + 逐条 existsSync。内存增量仅为 key 字符串引用复用
  // （Song/路径对象本身不复制），千条约几十 KB，车机可忽略。
  final Map<String, Set<String>> _playCacheByHash = {};
  bool _initialized = false;

  /// 桌面下载完成通知（仅桌面形态由 main.dart 注入；移动端/车机为 null，
  /// 全部通知逻辑零开销跳过）。
  DesktopDownloadNotifier? desktopNotifier;

  int _playCacheLimit = 300 * 1024 * 1024; // 默认 300MB
  int get playCacheLimit => _playCacheLimit;

  Future<void> setPlayCacheLimit(int limitInBytes) async {
    _playCacheLimit = limitInBytes;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_playCacheLimitKey, limitInBytes);
    notifyListeners();
    await _prunePlayCache(excludePaths: const {});
  }

  /// 启动时加载索引并校验文件存在性。
  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    final prefs = await SharedPreferences.getInstance();
    _playCacheLimit = prefs.getInt(_playCacheLimitKey) ?? (300 * 1024 * 1024);
    await _loadDownloads();
    await _loadPlayCache();
    // 启动时 LRU 清理播放缓存
    await _prunePlayCache(excludePaths: const {});
  }

  Future<void> _loadDownloads() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_downloadsIndexKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final list = jsonDecode(raw);
      if (list is! List) return;
      for (final item in list.whereType<Map<String, dynamic>>()) {
        final song = Song.fromCache(
          (item['song'] as Map).cast<String, dynamic>(),
        );
        final quality = AudioQuality.fromApiValue(item['quality'] as String?);
        final filePath = item['filePath'] as String?;
        if (filePath == null) continue;
        // 校验文件存在性
        if (!await _service.fileSize(filePath).then((s) => s > 0)) continue;
        final downloadedAtStr = item['downloadedAt'] as String?;
        _downloads[song.hash] = DownloadEntry(
          song: song,
          quality: quality,
          status: DownloadStatus.downloaded,
          filePath: filePath,
          downloadedAt: downloadedAtStr != null
              ? DateTime.tryParse(downloadedAtStr)
              : null,
        );
      }
    } catch (_) {}
  }

  Future<void> _loadPlayCache() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_playCacheIndexKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final list = jsonDecode(raw);
      if (list is! List) return;
      for (final item in list.whereType<Map<String, dynamic>>()) {
        final cacheKey = item['cacheKey'] as String? ?? '';
        final filePath = item['filePath'] as String?;
        if (filePath == null) continue;
        // 校验文件存在性
        final size = await _service.fileSize(filePath);
        if (size == 0) continue;
        final song = Song.fromCache(
          (item['song'] as Map).cast<String, dynamic>(),
        );
        final quality = AudioQuality.fromApiValue(item['quality'] as String?);
        final cachedAtStr = item['cachedAt'] as String?;
        final entry = PlayCacheEntry(
          cacheKey: cacheKey,
          song: song,
          quality: quality,
          filePath: filePath,
          size: size,
          cachedAt: cachedAtStr != null
              ? DateTime.tryParse(cachedAtStr) ?? DateTime.now()
              : DateTime.now(),
        );
        _playCache[cacheKey] = entry;
        _indexPlayCacheEntry(entry);
      }
    } catch (_) {}
  }

  void _indexPlayCacheEntry(PlayCacheEntry entry) {
    final set = _playCacheByHash.putIfAbsent(
      entry.song.hash,
      () => <String>{},
    );
    set.add(entry.cacheKey);
  }

  void _unindexPlayCacheEntry(PlayCacheEntry entry) {
    final set = _playCacheByHash[entry.song.hash];
    if (set == null) return;
    set.remove(entry.cacheKey);
    if (set.isEmpty) _playCacheByHash.remove(entry.song.hash);
  }

  Future<void> _persistDownloads() async {
    final prefs = await SharedPreferences.getInstance();
    final list = _downloads.values
        .where((e) => e.status == DownloadStatus.downloaded)
        .map(
          (e) => {
            'song': e.song.toCache(),
            'quality': e.quality.apiValue,
            'filePath': e.filePath,
            'downloadedAt': e.downloadedAt?.toIso8601String(),
          },
        )
        .toList();
    await prefs.setString(_downloadsIndexKey, jsonEncode(list));
  }

  Future<void> _persistPlayCache() async {
    final prefs = await SharedPreferences.getInstance();
    final list = _playCache.values
        .map(
          (e) => {
            'cacheKey': e.cacheKey,
            'song': e.song.toCache(),
            'quality': e.quality.apiValue,
            'filePath': e.filePath,
            'size': e.size,
            'cachedAt': e.cachedAt.toIso8601String(),
          },
        )
        .toList();
    await prefs.setString(_playCacheIndexKey, jsonEncode(list));
  }

  // ===== 查询 =====

  /// 返回本地文件路径：优先已下载 > 播放缓存（按当前音质）。无则 null。
  String? localPathFor(Song song, AudioQuality quality) {
    final key = _service.cacheKeyFor(song, quality);
    // 优先已下载（同音质）
    final download = _downloads[song.hash];
    if (download?.status == DownloadStatus.downloaded &&
        download?.filePath != null &&
        _service.cacheKeyFor(download!.song, download.quality) == key) {
      if (File(download.filePath!).existsSync()) {
        return download.filePath;
      }
    }
    // 其次播放缓存
    final cache = _playCache[key];
    if (cache != null && File(cache.filePath).existsSync()) {
      return cache.filePath;
    }
    return null;
  }

  /// 返回本地文件路径：优先首选音质（已下载 > 播放缓存）；
  /// 若未命中首选音质，降级检索该歌曲已下载或播放缓存中的任意有效文件。无则 null。
  ///
  /// 性能：同曲索引 [_playCacheByHash] 使降级只检查同 hash 的 1~2 条，
  /// 而非全表 O(n) existsSync。切歌主流程同步 IO 从 n 次降到常数次。
  String? localPathForAnyQuality(Song song, {AudioQuality? preferredQuality}) {
    if (preferredQuality != null) {
      final exact = localPathFor(song, preferredQuality);
      if (exact != null) return exact;
    }
    // 降级1：遍历同 hash 的已下载文件（不限音质）
    final download = _downloads[song.hash];
    if (download?.status == DownloadStatus.downloaded &&
        download?.filePath != null &&
        File(download!.filePath!).existsSync()) {
      return download.filePath;
    }
    // 降级2：同曲索引取候选（通常 1 条），只做常数次 existsSync
    final keys = _playCacheByHash[song.hash];
    if (keys != null) {
      for (final key in keys) {
        final entry = _playCache[key];
        if (entry != null && File(entry.filePath).existsSync()) {
          return entry.filePath;
        }
      }
    }
    return null;
  }

  bool isDownloaded(Song song) =>
      _downloads[song.hash]?.status == DownloadStatus.downloaded;

  DownloadEntry? entryFor(Song song) => _downloads[song.hash];

  List<Song> get downloadedSongs => _downloads.values
      .where((e) => e.status == DownloadStatus.downloaded)
      .map((e) => e.song)
      .toList();

  List<DownloadEntry> get downloadEntries => _downloads.values.toList();

  List<PlayCacheEntry> get playCacheEntries => _playCache.values.toList();

  /// 获取下载目录大小（字节）。
  Future<int> getDownloadDirSize() => _service.getDownloadDirSize();

  /// 获取播放缓存目录大小（字节）。
  Future<int> getPlayCacheDirSize() => _service.getPlayCacheDirSize();

  // ===== 下载操作 =====

  /// 用户主动下载歌曲。
  Future<void> download(Song song, AudioQuality quality) async {
    final hash = song.hash;
    final existing = _downloads[hash];
    if (existing?.status == DownloadStatus.downloading) return;
    if (existing?.status == DownloadStatus.downloaded) return;

    _downloads[hash] = DownloadEntry(
      song: song,
      quality: quality,
      status: DownloadStatus.downloading,
      progress: 0,
    );
    notifyListeners();

    try {
      final playUrl = await _api.songUrl(song, quality: quality);
      if (playUrl.url.isEmpty) {
        throw Exception('这首歌暂时没有可播放地址');
      }
      await _transfer(song, quality, playUrl.url);
    } catch (error) {
      _downloads[hash] = DownloadEntry(
        song: song,
        quality: quality,
        status: DownloadStatus.failed,
        error: error.toString(),
      );
      notifyListeners();
    }
  }

  /// 批量下载：把一组歌曲一次性加入现有下载队列。
  ///
  /// - 已下载、正在下载的歌曲自动跳过；
  /// - 播放地址解析失败或无地址的歌曲进入失败列表，可单独重试；
  /// - 地址解析采用有限并发（4 路），避免一次性发起大量请求；
  /// - 文件传输复用 [DownloadService] 的并发队列（上限
  ///   [AppConfig.maxConcurrentDownloads]），支持进度与断点续传。
  Future<BatchDownloadResult> enqueueBatch(
    List<Song> songs,
    AudioQuality quality,
  ) async {
    // 批次内按 hash 去重，避免同一首歌被重复下载。
    final seen = <String>{};
    songs = songs.where((song) => seen.add(song.hash)).toList();
    const urlConcurrency = 4;
    var enqueued = 0;
    var skipped = 0;
    var failed = 0;
    var cursor = 0;

    // 桌面形态：整个批次结束后一次性通知（[BatchDownloadTracker]），
    // 避免批量下载每曲一弹刷屏；移动端 desktopNotifier 为 null 直接跳过。
    // tracker 作为参数随传输闭包传递，并发批次互不串扰（旧批次残留事件
    // 计入旧 tracker，不再影响新批次）。
    BatchDownloadTracker? tracker;
    if (desktopNotifier != null) {
      tracker = BatchDownloadTracker(onComplete: _onBatchDownloadCompleted)
        ..begin();
    }

    Future<void> worker() async {
      while (cursor < songs.length) {
        final song = songs[cursor++];
        final hash = song.hash;
        final existing = _downloads[hash];
        if (existing?.status == DownloadStatus.downloading ||
            existing?.status == DownloadStatus.downloaded) {
          skipped++;
          continue;
        }

        _downloads[hash] = DownloadEntry(
          song: song,
          quality: quality,
          status: DownloadStatus.downloading,
          progress: 0,
        );
        notifyListeners();

        // 一个通知单元 = 一首歌的完整处理（地址解析 + 文件传输）：
        // 开始即计数，结束（无论成败）恰好一次，保证计数守恒。
        tracker?.trackStarted();
        try {
          final playUrl = await _api.songUrl(song, quality: quality);
          if (playUrl.url.isEmpty) {
            _downloads[hash] = DownloadEntry(
              song: song,
              quality: quality,
              status: DownloadStatus.failed,
              error: '这首歌暂时没有可播放地址',
            );
            notifyListeners();
            failed++;
            tracker?.trackFinished(succeeded: false);
            continue;
          }
          enqueued++;
          unawaited(
            _transfer(
              song,
              quality,
              playUrl.url,
              partOfBatch: true,
              batchTracker: tracker,
            ),
          );
        } catch (error) {
          _downloads[hash] = DownloadEntry(
            song: song,
            quality: quality,
            status: DownloadStatus.failed,
            error: error.toString(),
          );
          notifyListeners();
          failed++;
          tracker?.trackFinished(succeeded: false);
        }
      }
    }

    final workerCount = songs.length < urlConcurrency
        ? songs.length
        : urlConcurrency;
    await Future.wait([for (var i = 0; i < workerCount; i++) worker()]);
    return BatchDownloadResult(
      enqueued: enqueued,
      skipped: skipped,
      failed: failed,
    );
  }

  /// 文件传输（播放地址已解析）。成功后写入已下载索引，失败进入失败列表。
  ///
  /// [partOfBatch] 为 true 时完成事件交给本批次自带的 [batchTracker]
  /// （整个批次只通知一次，一次批量 = 一个任务 = 一条通知）；
  /// 为 false 时（单曲下载）成功即弹一次桌面通知。播放缓存不经过本方法，
  /// 不会被通知。
  Future<void> _transfer(
    Song song,
    AudioQuality quality,
    String url, {
    bool partOfBatch = false,
    BatchDownloadTracker? batchTracker,
  }) async {
    final hash = song.hash;
    var succeeded = false;
    try {
      final path = await _service.download(
        song: song,
        quality: quality,
        url: url,
        onProgress: (received, total) {
          final progress = total > 0 ? received / total : 0.0;
          final entry = _downloads[hash];
          if (entry?.status == DownloadStatus.downloading) {
            _downloads[hash] = entry!.copyWith(progress: progress);
            notifyListeners();
          }
        },
      );
      _downloads[hash] = DownloadEntry(
        song: song,
        quality: quality,
        status: DownloadStatus.downloaded,
        progress: 1,
        filePath: path,
        downloadedAt: DateTime.now(),
      );
      notifyListeners();
      await _persistDownloads();
      succeeded = true;
    } catch (error) {
      _downloads[hash] = DownloadEntry(
        song: song,
        quality: quality,
        status: DownloadStatus.failed,
        error: error.toString(),
      );
      notifyListeners();
    } finally {
      _notifyDesktopDownloadCompleted(
        song,
        partOfBatch: partOfBatch,
        succeeded: succeeded,
        batchTracker: batchTracker,
      );
    }
  }

  /// 桌面下载完成通知入口（非桌面 desktopNotifier 为 null 时零开销）。
  void _notifyDesktopDownloadCompleted(
    Song song, {
    required bool partOfBatch,
    required bool succeeded,
    BatchDownloadTracker? batchTracker,
  }) {
    if (partOfBatch) {
      // 交给本批次的聚合器：全部单元结束后统一通知一次。
      batchTracker?.trackFinished(succeeded: succeeded);
      return;
    }
    // 单曲下载：只对成功弹通知；失败沿用页内失败列表提示。
    if (!succeeded) return;
    desktopNotifier?.notifyDownloadCompleted(
      title: kDownloadNotificationTitle,
      body: singleDownloadNotificationBody(
        songTitle: song.title,
        artist: song.artist,
      ),
    );
  }

  /// 批量下载全部结束后的一次性通知。
  void _onBatchDownloadCompleted(int succeeded, int failed) {
    desktopNotifier?.notifyDownloadCompleted(
      title: kDownloadNotificationTitle,
      body: batchDownloadNotificationBody(
        succeeded: succeeded,
        failed: failed,
      ),
    );
  }

  /// 移除一条失败记录（从失败列表清除）。
  void removeFailed(Song song) {
    final entry = _downloads[song.hash];
    if (entry?.status != DownloadStatus.failed) return;
    _downloads.remove(song.hash);
    notifyListeners();
  }

  /// 取消下载。
  Future<void> cancelDownload(Song song) async {
    final hash = song.hash;
    final entry = _downloads[hash];
    if (entry?.status != DownloadStatus.downloading) return;
    final key = _service.cacheKeyFor(song, entry!.quality);
    await _service.cancel(key);
    _downloads.remove(hash);
    notifyListeners();
  }

  /// 删除单个已下载歌曲。
  Future<void> deleteDownload(Song song) async {
    final hash = song.hash;
    final entry = _downloads[hash];
    if (entry?.filePath != null) {
      await _service.deleteFile(entry!.filePath!);
    }
    _downloads.remove(hash);
    notifyListeners();
    await _persistDownloads();
  }

  /// 清空所有已下载歌曲。
  ///
  /// 快照后删除：传输协程可能在 await 间隙改 [_downloads]，直接遍历
  /// values 会抛 ConcurrentModificationError。先取消在途任务再删文件。
  /// 注意：在播文件如正被代理 openRead serving，删后后续 Range 会 404；
  /// 跨控制器停播/跳过需 player 协作，属大改，另开分支处理，这里只保不崩。
  Future<void> clearAllDownloads() async {
    final snapshot = List.of(_downloads.values);
    for (final entry in snapshot) {
      if (entry.status == DownloadStatus.downloading) {
        try {
          await _service.cancel(
            _service.cacheKeyFor(entry.song, entry.quality),
          );
        } catch (_) {}
      }
    }
    for (final entry in snapshot) {
      if (entry.filePath != null) {
        await _service.deleteFile(entry.filePath!);
      }
    }
    _downloads.clear();
    notifyListeners();
    await _persistDownloads();
  }

  // ===== 播放缓存 =====

  /// 后台缓存当前播放歌曲（首播后调用）。url 来自 songUrl 结果。
  Future<void> cacheForPlayback(
    Song song,
    AudioQuality quality,
    String url,
  ) async {
    final key = _service.cacheKeyFor(song, quality);
    // 已有缓存或已在下载则跳过
    if (_playCache[key] != null) return;
    if (_downloads[song.hash]?.status == DownloadStatus.downloading) return;

    try {
      final path = await _service.cacheForPlayback(
        song: song,
        quality: quality,
        url: url,
      );
      final size = await _service.fileSize(path);
      final entry = PlayCacheEntry(
        cacheKey: key,
        song: song,
        quality: quality,
        filePath: path,
        size: size,
        cachedAt: DateTime.now(),
      );
      _playCache[key] = entry;
      _indexPlayCacheEntry(entry);
      notifyListeners();
      await _persistPlayCache();
      // LRU 清理
      await _prunePlayCache(excludePaths: {path});
    } catch (_) {
      // 播放缓存失败静默忽略
    }
  }

  /// 清空所有播放缓存。
  Future<void> clearPlayCache() async {
    await _service.clearPlayCacheDir();
    _playCache.clear();
    _playCacheByHash.clear();
    notifyListeners();
    await _persistPlayCache();
  }

  /// 删除单首播放缓存。
  Future<void> deletePlayCache(Song song, AudioQuality quality) async {
    final key = _service.cacheKeyFor(song, quality);
    final entry = _playCache[key];
    if (entry != null) {
      await _service.deleteFile(entry.filePath);
      _playCache.remove(key);
      _unindexPlayCacheEntry(entry);
      notifyListeners();
      await _persistPlayCache();
    }
  }

  Future<void> _prunePlayCache({Set<String> excludePaths = const {}}) async {
    final entries =
        _playCache.values
            .map(
              (e) => (
                cacheKey: e.cacheKey,
                filePath: e.filePath,
                cachedAt: e.cachedAt,
              ),
            )
            .toList()
          ..sort((a, b) => a.cachedAt.compareTo(b.cachedAt));

    await _service.prunePlayCache(
      entries,
      maxBytes: _playCacheLimit,
      excludePaths: excludePaths,
    );

    // 清理后校验索引，移除已删除的条目
    final toRemove = <String>[];
    for (final entry in _playCache.values) {
      final size = await _service.fileSize(entry.filePath);
      if (size == 0 && !excludePaths.contains(entry.filePath)) {
        toRemove.add(entry.cacheKey);
      }
    }
    if (toRemove.isNotEmpty) {
      for (final key in toRemove) {
        final removed = _playCache.remove(key);
        if (removed != null) _unindexPlayCacheEntry(removed);
      }
      notifyListeners();
      await _persistPlayCache();
    }
  }
}
