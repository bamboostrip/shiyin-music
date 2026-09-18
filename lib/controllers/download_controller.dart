import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/music_models.dart';
import '../services/desktop_system_integration.dart';
import '../services/download_service.dart';
import '../services/music_api.dart';
import '../ui/widgets/toast.dart';

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

  static const _downloadsIndexKey = 'shiyin_downloads_index';
  static const _playCacheIndexKey = 'shiyin_play_cache_index';
  static const _playCacheLimitKey = 'settings.play_cache_limit';

  final Map<String, DownloadEntry> _downloads = {}; // key = hash
  final Map<String, PlayCacheEntry> _playCache = {}; // key = hash_quality
  // 同曲索引：hash -> cacheKey 集合，避免 AnyQuality 查询时 O(n) 全表
  // 扫描 + 逐条 existsSync。内存增量仅为 key 字符串引用复用
  // （Song/路径对象本身不复制），千条约几十 KB，车机可忽略。
  final Map<String, Set<String>> _playCacheByHash = {};
  bool _initialized = false;

  /// 在途播放缓存任务（cacheKey 去重）：同一首歌重复触发缓存时直接跳过，
  /// 避免并发任务争抢同一个 .part 文件（service 层同键去重是第二道兜底）。
  final Set<String> _inFlightCacheKeys = {};

  /// 桌面下载完成通知（仅桌面形态由 main.dart 注入；移动端/车机为 null，
  /// 全部通知逻辑零开销跳过）。
  DesktopDownloadNotifier? desktopNotifier;

  /// 代际：clearAll 时递增，在途传输与批量 worker 凭此丢弃过期结果，
  /// 避免清空后复活 failed/downloaded 条目。
  int _generation = 0;

  /// 控制器是否已销毁。地址解析（最多 20s）与文件传输（分钟级）期间
  /// 可能跨 dispose 存活，回调里凭此不再写回条目、不再 notifyListeners
  /// （对已 dispose 的 ChangeNotifier，debug 构建会抛 used after being
  /// disposed）。_generation 只服务 clearAllDownloads，不服务 dispose。
  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  /// 在播本地路径提供方（main.dart 注入 player 的当前歌曲路径）。
  /// 清理/裁剪时保护该文件，避免播一半被删导致后续 Range 404。
  String? Function()? playingPathProvider;

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
    // 磁盘对账：历史目录迁移（桌面）+ 外部删除同步，随加载一次完成
    await reconcileDownloads();
    await _loadPlayCache();
    // 启动时 LRU 清理播放缓存
    await _prunePlayCache(excludePaths: const {});
  }

  Future<void> _loadDownloads() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_downloadsIndexKey);
    if (raw == null || raw.isEmpty) return;
    late final List decoded;
    try {
      decoded = jsonDecode(raw) as List;
    } catch (_) {
      return;
    }
    // 逐条容错：单条损坏只跳过该条，避免一条坏数据吃掉全表；
    // 有裁剪则回写，把坏条一次性清理，下次启动不再重复解析。
    // 不做常规的文件存在性校验——外部删除/目录布局变迁的找回与裁剪
    // 统一交给 [reconcileDownloads]（加载即裁会误删"改名迁移只重写了
    // 索引、文件仍在旧目录"的错位条目）；仅同 hash 重复条目在加载时
    // 择优（见循环内注释），避免丢失条目顶掉好条目。
    var dropped = 0;
    for (final item in decoded) {
      if (item is! Map<String, dynamic>) {
        dropped++;
        continue;
      }
      try {
        final songMap = item['song'];
        if (songMap is! Map) throw const FormatException('bad song');
        final song = Song.fromCache(songMap.cast<String, dynamic>());
        final quality = AudioQuality.fromApiValue(item['quality'] as String?);
        final filePath = item['filePath'] as String?;
        if (filePath == null) throw const FormatException('no path');
        // 同 hash 重复条目（历史索引里同一首歌以不同音质记了两条）：
        // 优先保留文件仍在磁盘上的那条——"后条覆盖前条"会让丢失条目
        // 顶掉好条目，随后被对账清掉，下载凭空消失。
        final existing = _downloads[song.hash];
        if (existing?.filePath != null) {
          final newPathExists = await File(filePath).exists();
          final oldPathExists = await File(existing!.filePath!).exists();
          if (!newPathExists && oldPathExists) {
            dropped++;
            continue;
          }
        }
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
      } catch (_) {
        dropped++;
      }
    }
    if (dropped > 0) {
      debugPrint('[时音][download] 索引裁剪 $dropped 条坏数据并回写');
      await _persistDownloads();
    }
  }

  Future<void> _loadPlayCache() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_playCacheIndexKey);
    if (raw == null || raw.isEmpty) return;
    late final List decoded;
    try {
      decoded = jsonDecode(raw) as List;
    } catch (_) {
      return;
    }
    var dropped = 0;
    for (final item in decoded) {
      if (item is! Map<String, dynamic>) {
        dropped++;
        continue;
      }
      try {
        final cacheKey = item['cacheKey'] as String? ?? '';
        final filePath = item['filePath'] as String?;
        if (filePath == null) throw const FormatException('no path');
        // 校验文件存在性
        final size = await _service.fileSize(filePath);
        if (size == 0) {
          dropped++;
          continue;
        }
        final songMap = item['song'];
        if (songMap is! Map) throw const FormatException('bad song');
        final song = Song.fromCache(songMap.cast<String, dynamic>());
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
      } catch (_) {
        dropped++;
      }
    }
    if (dropped > 0) {
      debugPrint('[时音][download] 播放缓存裁剪 $dropped 条坏数据并回写');
      await _persistPlayCache();
    }
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
    final key = _service.cacheKeyFor(song, quality);
    final existing = _downloads[hash];
    if (existing?.status == DownloadStatus.downloading) return;
    if (existing?.status == DownloadStatus.downloaded) return;
    // 同键下载任务已在途/排队（service 按 kind:cacheKey 去重，此处为
    // 快速路径）：跳过。播放缓存与下载写不同目录，互不阻塞。
    if (_service.inFlightKeysFor(DownloadTaskKind.download).contains(key)) {
      return;
    }

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
      // 等待地址解析期间已被清空/取消（条目移除）：不再写回失败条目。
      // _transfer 内部自捕获不会抛到此处，能到这里只会是解析本身失败。
      if (_downloads[hash]?.status != DownloadStatus.downloading) return;
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
    // 代际快照：中途 clearAll 会递增代际，worker 凭此停掉，
    // 不再把旧批次结果写回已清空的表
    final gen = _generation;

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
      while (cursor < songs.length && gen == _generation && !_disposed) {
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
          // 等待解析期间已被清空/取消（代际过期或条目不在下载态）：
          // 静默中止，不写回条目；tracker 仍要结束计数以保守恒。
          if (_disposed ||
              gen != _generation ||
              _downloads[hash]?.status != DownloadStatus.downloading) {
            tracker?.trackFinished(succeeded: false);
            continue;
          }
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
          if (_disposed ||
              gen != _generation ||
              _downloads[hash]?.status != DownloadStatus.downloading) {
            tracker?.trackFinished(succeeded: false);
            continue;
          }
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
    // 代际快照：clearAll 后完成的传输直接丢弃，不复活条目
    final gen = _generation;
    var succeeded = false;
    try {
      // 启动前复核：等待地址解析期间条目可能已被清空/取消（移除），
      // 此时不再发起传输，避免已清空的歌"复活"。守卫放 try 内，
      // finally 的桌面通知/tracker 记账仍恰好一次（单曲失败不弹、
      // 批次照常 trackFinished，计数守恒不破坏）。
      if (_downloads[hash]?.status != DownloadStatus.downloading) {
        return;
      }
      final path = await _service.download(
        song: song,
        quality: quality,
        url: url,
        onProgress: (received, total) {
          if (_disposed) return;
          final progress = total > 0 ? received / total : 0.0;
          final entry = _downloads[hash];
          if (entry?.status == DownloadStatus.downloading) {
            _downloads[hash] = entry!.copyWith(progress: progress);
            notifyListeners();
          }
        },
      );
      if (gen != _generation || _disposed) {
        debugPrint('[时音][download] 代际过期，丢弃传输结果: ${song.title}');
        return;
      }
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
      if (gen != _generation || _disposed) {
        // 清空后落地的过期结果（含取消）：直接丢弃，不复活条目
        return;
      }
      if (error is DioException && error.type == DioExceptionType.cancel) {
        // 用户主动取消：保持移除状态，不写失败条目（否则“已取消”变“下载失败”）
        _downloads.remove(hash);
        notifyListeners();
        return;
      }
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

  /// 目标路径是否为当前正在播放的文件（在播保护，同 [clearPlayCache] 口径）。
  bool _isPlayingFile(String path) => playingPathProvider?.call() == path;

  /// 删除单个已下载歌曲。
  Future<void> deleteDownload(Song song) async {
    final hash = song.hash;
    final entry = _downloads[hash];
    if (entry?.filePath != null) {
      if (_isPlayingFile(entry!.filePath!)) {
        // 在播文件删了会打断播放（代理后续 Range 404），保留条目待播完再删。
        Toast.show('正在播放，已跳过文件删除');
        return;
      }
      await _service.deleteFile(entry.filePath!);
    }
    _downloads.remove(hash);
    notifyListeners();
    await _persistDownloads();
  }

  /// 清空所有已下载歌曲。
  ///
  /// 快照后删除：传输协程可能在 await 间隙改 [_downloads]，直接遍历
  /// values 会抛 ConcurrentModificationError。先取消在途任务再删文件，
  /// 并递增代际使在途传输与批量 worker 丢弃过期结果（不复活条目）。
  /// 注意：在播文件如正被代理 openRead serving，删后后续 Range 会 404；
  /// 跨控制器停播/跳过需 player 协作，属大改，另开分支处理，这里只保不崩。
  Future<void> clearAllDownloads() async {
    _generation++;
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

  // ===== 索引与磁盘对账 =====

  /// 下载索引对账：让列表回到与磁盘一致的真实状态。
  ///
  /// 两个来源会造成索引与磁盘脱节：
  /// 1. 桌面端下载落点两次变迁（ka_music 改名、Windows 从文档目录对齐
  ///    系统 Downloads），旧条目的绝对路径可能指向历史目录；
  /// 2. 用户在文件管理器里手动删除/移动歌曲文件，索引无从感知。
  ///
  /// 对每个已下载条目（现代桌面软件"以文件为准、列表随磁盘"的口径）：
  /// - 文件仍在历史目录 → 搬入当前下载目录并重写路径（仅桌面，
  ///   [DownloadService.legacyDownloadDirs] 在移动端返回空列表）；
  /// - 索引路径已失效，但同名文件在当前/历史目录 → 采用（覆盖改名
  ///   迁移只重写了索引字符串、文件仍在旧目录的错位）；
  /// - 到处不存在 → 移除条目（外部删除同步）。
  ///
  /// 启动时（[initialize]）静默执行；「已下载」页打开时再次执行并按
  /// 返回值提示。搬移/采用不提示（一次性迁移，不打扰）。在播文件不
  /// 参与搬移（rename 会中断播放，留待下次对账）。返回移除的条目数。
  Future<int> reconcileDownloads() async {
    if (_disposed) return 0;
    Directory? currentDir;
    List<Directory> legacyDirs = const [];
    try {
      currentDir = await _service.downloadDir();
    } catch (_) {}
    try {
      legacyDirs = await _service.legacyDownloadDirs();
    } catch (_) {}
    // 下载根都解析/创建失败（下载卷未挂载、共享盘断开等）时 exists()
    // 会全员 false，此时裁剪等于把整张索引清空，存储恢复后"下载全丢"。
    // 只在下载根可用时才判定"外部删除"；根不可用时本轮保留所有条目。
    final canPrune = currentDir != null;

    var changed = false;
    var removed = 0;
    // 快照遍历：搬移/移除结果先记账，循环后统一写回表
    final snapshot = List.of(_downloads.values);
    final rewrites = <String, String>{}; // hash -> 磁盘上的真实路径
    final drops = <String>{};
    for (final entry in snapshot) {
      if (entry.status != DownloadStatus.downloaded) continue;
      final path = entry.filePath;
      if (path == null || path.isEmpty) continue;
      final file = File(path);
      final name = _basenameOf(path);

      if (await file.exists()) {
        // 文件在历史目录中 → 搬入当前目录（同目录体系的条目不动）。
        // 目录比较为字符串精确匹配：候选与索引路径同源于 downloadDir 的
        // '<原生分隔符目录>/<名字>' 拼接口径，构造上必然一致（Windows
        // 大小写漂移只会退化为"不搬移"，安全无害）。
        if (currentDir != null &&
            legacyDirs.any((d) => d.path == file.parent.path) &&
            !_isPlayingFile(path)) {
          final moved = await _moveIntoDownloadDir(file, currentDir);
          if (moved != null) {
            rewrites[entry.song.hash] = moved;
            changed = true;
          }
        }
        continue;
      }

      // 索引路径失效：同名文件找回——当前目录优先，其次历史目录（搬入）
      if (currentDir != null && name != null) {
        final candidate = File('${currentDir.path}/$name');
        if (await candidate.exists()) {
          rewrites[entry.song.hash] = candidate.path;
          changed = true;
          continue;
        }
      }
      String? legacyHit;
      if (name != null) {
        for (final dir in legacyDirs) {
          final candidate = File('${dir.path}/$name');
          if (await candidate.exists()) {
            legacyHit = candidate.path;
            break;
          }
        }
      }
      if (legacyHit != null) {
        var resolved = legacyHit;
        if (currentDir != null && !_isPlayingFile(legacyHit)) {
          final moved = await _moveIntoDownloadDir(File(legacyHit), currentDir);
          if (moved != null) resolved = moved;
          // 搬移失败（文件被占用等）：索引指向历史路径原地采用，仍可播
        }
        rewrites[entry.song.hash] = resolved;
        changed = true;
        continue;
      }

      // 到处不存在：外部已删除，移除条目（存储不可用时见 canPrune 注释）
      if (!canPrune) continue;
      drops.add(entry.song.hash);
      removed++;
      changed = true;
    }

    if (!changed) return 0;
    for (final entry in snapshot) {
      final hash = entry.song.hash;
      // 对账期间用户已对该条目发起删除/重下（表内对象已换）：以最新
      // 状态为准，不回写过期结论（如删掉刚重下的条目、复活刚删的）。
      if (!identical(_downloads[hash], entry)) continue;
      if (drops.contains(hash)) {
        _downloads.remove(hash);
      } else if (rewrites.containsKey(hash)) {
        _downloads[hash] = entry.copyWith(filePath: rewrites[hash]);
      }
    }
    debugPrint(
      '[时音][download] 对账完成：搬移/采用 ${rewrites.length} 条，'
      '移除 $removed 条',
    );
    notifyListeners();
    await _persistDownloads();
    return removed;
  }

  /// 把历史目录中的文件搬入当前下载目录，返回新路径；失败返回 null
  /// （条目保持旧路径继续可播）。同名冲突沿用下载完成时的口径
  /// （[DownloadService.resolveNonCollidingPath]）：目标已存在且同大小
  /// 视为同一内容，索引直接指向现有文件、源文件留在原地（绝不自动
  /// 删除用户数据）；不同大小换 "(n)" 名保留两份。
  Future<String?> _moveIntoDownloadDir(File source, Directory dir) async {
    try {
      final name = _basenameOf(source.path);
      if (name == null) return null;
      final target = '${dir.path}/$name';
      final finalPath = _service.resolveNonCollidingPath(target, source.path);
      if (finalPath == target && File(target).existsSync()) {
        // resolve 判定为同内容重复：采用现有文件，不动源文件
        return target;
      }
      await source.rename(finalPath);
      return finalPath;
    } on FileSystemException catch (_) {
      // 跨盘/跨卷 rename（如 C 盘默认目录 ↔ D 盘自定义目录）必失败：
      // 外层 try 的局部变量在 catch 子句不可见，这里按源路径重算目标
      // （对账是快照遍历，无并发改名，结论一致）。
      final name = _basenameOf(source.path);
      if (name == null) return null;
      final target = '${dir.path}/$name';
      final retryPath = _service.resolveNonCollidingPath(target, source.path);
      try {
        await source.copy(retryPath);
        await source.delete();
        return retryPath;
      } catch (error) {
        debugPrint('[时音][download] 历史目录文件跨盘搬移失败（保留原路径）: $error');
        // 复制成功但删源失败时目标已落地：索引指向新路径，源残留由用户清理，
        // 不视为失败（复制失败则落到外层统一保留原路径）。
        if (File(retryPath).existsSync()) return retryPath;
        return null;
      }
    } catch (error) {
      debugPrint('[时音][download] 历史目录文件搬移失败（保留原路径）: $error');
      return null;
    }
  }

  /// 路径最后一段文件名（兼容 `\` 与 `/` 分隔）；空路径返回 null。
  String? _basenameOf(String path) {
    final normalized = path.replaceAll('\\', '/');
    final index = normalized.lastIndexOf('/');
    final name = index >= 0 ? normalized.substring(index + 1) : normalized;
    return name.isEmpty ? null : name;
  }

  // ===== 播放缓存 =====

  /// 后台缓存当前播放歌曲（首播后调用）。url 来自 songUrl 结果。
  Future<void> cacheForPlayback(
    Song song,
    AudioQuality quality,
    String url,
  ) async {
    final key = _service.cacheKeyFor(song, quality);
    // 已有缓存、已在下载或在途缓存任务则跳过
    if (_playCache[key] != null) return;
    if (_downloads[song.hash]?.status == DownloadStatus.downloading) return;
    if (_inFlightCacheKeys.contains(key)) return;
    _inFlightCacheKeys.add(key);

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
    } finally {
      _inFlightCacheKeys.remove(key);
    }
  }

  /// 清空所有播放缓存（保留在播文件与在途任务条目）。
  ///
  /// 在播文件由 [playingPathProvider] 提供保护（删了播一半会 404 中断）；
  /// 在途任务的索引条目保留，任务结束自己写回；service 层同时跳过
  /// exclude 与 .part 半成品。
  Future<void> clearPlayCache({Set<String> excludePaths = const {}}) async {
    final effective = <String>{...excludePaths};
    final playing = playingPathProvider?.call();
    if (playing != null) effective.add(playing);
    final inFlight = _service.inFlightKeysFor(DownloadTaskKind.playCache);
    await _service.clearPlayCacheDir(excludePaths: effective);
    _playCache.removeWhere(
      (key, e) =>
          !effective.contains(e.filePath) && !inFlight.contains(key),
    );
    _playCacheByHash.clear();
    for (final e in _playCache.values) {
      _indexPlayCacheEntry(e);
    }
    notifyListeners();
    await _persistPlayCache();
  }

  /// 删除单首播放缓存。
  Future<void> deletePlayCache(Song song, AudioQuality quality) async {
    final key = _service.cacheKeyFor(song, quality);
    final entry = _playCache[key];
    if (entry == null) return;
    if (_isPlayingFile(entry.filePath)) {
      // 在播文件暂不删（播一半 404），保留条目，与 clearPlayCache 的在播保护一致。
      Toast.show('正在播放，已跳过文件删除');
      return;
    }
    await _service.deleteFile(entry.filePath);
    _playCache.remove(key);
    _unindexPlayCacheEntry(entry);
    notifyListeners();
    await _persistPlayCache();
  }

  Future<void> _prunePlayCache({Set<String> excludePaths = const {}}) async {
    // 在播文件永远不参与 LRU 驱逐（调小上限/启动清理时正在播的最旧文件
    // 也不能删，否则播一半 404）
    final playing = playingPathProvider?.call();
    final effective =
        playing == null ? excludePaths : {...excludePaths, playing};
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
      excludePaths: effective,
    );

    // 清理后校验索引，移除已删除的条目
    final toRemove = <String>[];
    for (final entry in _playCache.values) {
      final size = await _service.fileSize(entry.filePath);
      if (size == 0 && !effective.contains(entry.filePath)) {
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
