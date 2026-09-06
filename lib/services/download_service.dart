import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:path_provider/path_provider.dart';

import '../config/app_config.dart';
import '../models/music_models.dart';

/// 下载任务类型。
enum DownloadTaskKind { download, playCache }

/// 内部待执行任务。
class _PendingTask {
  _PendingTask({
    required this.kind,
    required this.song,
    required this.quality,
    required this.url,
    required this.completer,
    this.onProgress,
  });

  final DownloadTaskKind kind;
  final Song song;
  final AudioQuality quality;
  final String url;
  final Completer<String> completer;
  final void Function(int received, int total)? onProgress;
}

/// 歌曲下载服务（IO 层 + dio 下载 + 并发管理）。
///
/// 下载到持久目录（用户主动下载），播放缓存到临时目录（系统可清理）。
/// 两者共享并发上限，用户主动下载优先。
class DownloadService {
  DownloadService();

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(minutes: 10),
  ));
  final Map<String, CancelToken> _cancelTokens = {};
  // key -> 在途 .part 路径（清理时识别 transient 半成品）
  final Map<String, String> _partPaths = {};
  final int _maxConcurrent = AppConfig.maxConcurrentDownloads;
  int _running = 0;
  final List<_PendingTask> _queue = [];

  /// 持久下载目录。
  ///
  /// - Android：App 专属外部目录（`Android/data/<包名>/files/ka_music_downloads`），
  ///   无需存储权限，卸载自动清理，不被系统相册/音乐扫描。
  ///   API29+ 分区存储下公共 Download 裸写必 EACCES，故不再使用公共目录。
  ///   存量用户旧索引仍是公共目录绝对路径，文件本身还在就继续可播可删；
  ///   新下载落新目录，目录大小统计口径随之切换（一次性显示回落，属预期）。
  /// - 桌面端（Windows/Linux/macOS）：系统"下载"目录（path_provider 的
  ///   getDownloadsDirectory：Windows 是 shell Downloads 已知目录，Linux 是
  ///   XDG Downloads）——与"歌曲已保存到下载目录"的通知文案、更新包
  ///   落点（app_update_service 同用 Downloads）保持一致；
  /// - 其他平台（iOS 等）或获取失败时回退到应用文档目录。
  Future<Directory> downloadDir() async {
    if (Platform.isAndroid) {
      try {
        final external = await getExternalStorageDirectory();
        if (external != null) {
          return _ensureDir(
            Directory('${external.path}/${AppConfig.downloadDirName}'),
          );
        }
      } catch (_) {
        // 取外部目录失败（如外置存储未挂载）则落到文档目录兜底
      }
      final base = await getApplicationDocumentsDirectory();
      return _ensureDir(
        Directory('${base.path}/${AppConfig.downloadDirName}'),
      );
    }
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      final downloadsDir = await getDownloadsDirectory();
      if (downloadsDir != null) {
        final dir =
            Directory('${downloadsDir.path}/${AppConfig.downloadDirName}');
        return _ensureDir(dir);
      }
      final base = await getApplicationDocumentsDirectory();
      return _ensureDir(
        Directory('${base.path}/${AppConfig.downloadDirName}'),
      );
    }
    final base = await getApplicationDocumentsDirectory();
    return _ensureDir(
      Directory('${base.path}/${AppConfig.downloadDirName}'),
    );
  }

  /// 目录确保存在；创建失败（如 XDG 目录指向无权限位置）原样抛出，
  /// 由调用方转为用户可读的下载失败提示。
  Future<Directory> _ensureDir(Directory dir) async {
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// 临时播放缓存目录。
  Future<Directory> playCacheDir() async {
    final base = await getTemporaryDirectory();
    final dir = Directory('${base.path}/${AppConfig.playCacheDirName}');
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// 文件名清洗时单段（歌手/歌名）的码点上限。
  ///
  /// Windows NTFS 单组件 255 字符 + 未开 LongPathsEnabled 时整路径 260：
  /// 叠加下载目录前缀与"歌手-歌名.flac"两段，超长歌名（酷狗常见
  /// "【超清Hi-Res】…"长后缀）会在 CreateFile 处永久失败且重试必现。
  /// 120 码点（中文约 120 字）对单曲名足够宽裕。
  static const int _kMaxNameComponentLength = 120;

  /// 文件命名：{歌手}-{歌曲名}.{ext}
  String fileNameFor(Song song, AudioQuality quality) {
    final ext = quality == AudioQuality.lossless ? 'flac' : 'mp3';
    final safeArtist = _sanitizeFileName(song.artist);
    final safeTitle = _sanitizeFileName(song.title);
    final name = (safeArtist.isNotEmpty && safeTitle.isNotEmpty)
        ? '$safeArtist-$safeTitle'
        : song.hash.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '');
    return '$name.$ext';
  }

  /// 移除文件名中不合法的字符（供单测）。
  ///
  /// - 三平台文件系统非法字符 `\ / : * ? " < > |` → `_`；
  /// - 控制字符（0x00-0x1F，API 偶发 `\n` 等）整段剥离：Linux 文件名合法
  ///   而 Windows CreateFile 拒绝，两端行为必须一致；
  /// - 压缩连续 `_` 与首尾空白/下划线；
  /// - 超长截断到 [_kMaxNameComponentLength] 码点（Windows 255 字符/组件
  ///   与 MAX_PATH 260 限制，避免超长歌名成为"重试必失败"的毒丸下载）。
  @visibleForTesting
  String sanitizeFileName(String name) => _sanitizeFileName(name);

  String _sanitizeFileName(String name) {
    var cleaned = name
        .replaceAll(RegExp(r'[\x00-\x1f]'), '')
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceFirst(RegExp(r'^_+'), '')
        .replaceFirst(RegExp(r'_+$'), '')
        .trim();
    if (cleaned.length > _kMaxNameComponentLength) {
      cleaned = cleaned.substring(0, _kMaxNameComponentLength)
          .replaceFirst(RegExp(r'[_\s]+$'), '');
    }
    return cleaned;
  }

  /// 缓存 key：{hash}_{quality.apiValue}
  String cacheKeyFor(Song song, AudioQuality quality) {
    final safeHash = song.hash.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '');
    return '${safeHash}_${quality.apiValue}';
  }

  /// 下载到持久目录（用户下载）。支持断点续传。
  ///
  /// [onProgress] 回调 (received, total)。返回最终文件路径。
  Future<String> download({
    required Song song,
    required AudioQuality quality,
    required String url,
    required void Function(int received, int total) onProgress,
  }) async {
    final completer = Completer<String>();
    final task = _PendingTask(
      kind: DownloadTaskKind.download,
      song: song,
      quality: quality,
      url: url,
      completer: completer,
      onProgress: onProgress,
    );
    _enqueue(task);
    return completer.future;
  }

  /// 下载到临时缓存目录（播放缓存）。无进度上报（静默）。
  Future<String> cacheForPlayback({
    required Song song,
    required AudioQuality quality,
    required String url,
  }) async {
    final completer = Completer<String>();
    final task = _PendingTask(
      kind: DownloadTaskKind.playCache,
      song: song,
      quality: quality,
      url: url,
      completer: completer,
    );
    _enqueue(task);
    return completer.future;
  }

  void _enqueue(_PendingTask task) {
    // 用户下载优先：插入队列头部之后（在其它下载任务之后、播放缓存之前）
    if (task.kind == DownloadTaskKind.download) {
      // 插入到第一个 playCache 任务之前
      final firstPlayCache = _queue
          .indexWhere((t) => t.kind == DownloadTaskKind.playCache);
      if (firstPlayCache >= 0) {
        _queue.insert(firstPlayCache, task);
      } else {
        _queue.add(task);
      }
    } else {
      _queue.add(task);
    }
    _processQueue();
  }

  Future<void> _processQueue() async {
    if (_running >= _maxConcurrent) return;
    if (_queue.isEmpty) return;

    final task = _queue.removeAt(0);
    _running++;

    try {
      final path = await _executeTask(task);
      task.completer.complete(path);
    } catch (error) {
      task.completer.completeError(error);
    } finally {
      _running--;
      _processQueue();
    }
  }

  Future<String> _executeTask(_PendingTask task) async {
    final key = cacheKeyFor(task.song, task.quality);
    final fileName = fileNameFor(task.song, task.quality);
    final dir = task.kind == DownloadTaskKind.download
        ? await downloadDir()
        : await playCacheDir();
    final targetPath = '${dir.path}/$fileName';
    // .part 带 cacheKey：不同歌曲清洗出同名文件（大小写变体/非法字符
    // 归一）时若共用 partPath，并发下载会互相写对方的半成品。
    final partPath = '$targetPath.$key.part';
    // 升级迁移：旧版 partPath 为 $targetPath.part（不带 key），新版无法
    // 复用，残留即垃圾。首次遇到顺手删除，避免公共 Download 目录堆积。
    final legacyPart = File('$targetPath.part');
    if (legacyPart.path != partPath && legacyPart.existsSync()) {
      try {
        await legacyPart.delete();
      } catch (_) {}
    }
    final cancelToken = CancelToken();
    _cancelTokens[key] = cancelToken;
    _partPaths[key] = partPath;

    try {
      try {
        await downloadWithResume(
          dio: _dio,
          url: task.url,
          partPath: partPath,
          onProgress: task.onProgress,
          cancelToken: cancelToken,
        );
      } on DioException catch (error) {
        // 416 Range Not Satisfiable：.part 比远端资源还长（脏数据），
        // 删掉整包重下，否则该任务永久失败。
        if (error.response?.statusCode == 416) {
          try {
            await File(partPath).delete();
          } on Exception {
            // 删除失败（被占用等）：交给下一次重试再清。
          }
          await downloadWithResume(
            dio: _dio,
            url: task.url,
            partPath: partPath,
            onProgress: task.onProgress,
            cancelToken: cancelToken,
          );
        } else {
          rethrow;
        }
      }

      // 下载完成，重命名 .part 为最终文件。目标已存在且大小与本次产物
      // 不同视为"同名不同歌"（大小写不敏感文件系统上大小写变体、或
      // 非法字符归一后的碰撞），换名保留两份，绝不静默覆盖另一首歌；
      // 大小相同几乎必为同一内容（同歌重下），覆盖无副作用。
      final finalPath = resolveNonCollidingPath(targetPath, partPath);
      if (finalPath != targetPath && File(targetPath).existsSync()) {
        debugPrint(
          '[DownloadService] 目标文件已存在且大小不同，避免覆盖: '
          '$targetPath -> ${File(finalPath).uri.pathSegments.last}',
        );
      }
      await File(partPath).rename(finalPath);

      return finalPath;
    } finally {
      _cancelTokens.remove(key);
      _partPaths.remove(key);
    }
  }

  /// 目标已存在且与 .part 大小不一致时，返回带序号的备选路径（供单测）。
  @visibleForTesting
  String resolveNonCollidingPath(String targetPath, String partPath) {
    final partFile = File(partPath);
    if (!partFile.existsSync()) return targetPath;
    final target = File(targetPath);
    if (!target.existsSync() ||
        target.lengthSync() == partFile.lengthSync()) {
      return targetPath;
    }
    final dot = targetPath.lastIndexOf('.');
    final stem = dot > 0 ? targetPath.substring(0, dot) : targetPath;
    final ext = dot > 0 ? targetPath.substring(dot) : '';
    var index = 2;
    while (File('$stem ($index)$ext').existsSync()) {
      index++;
    }
    return '$stem ($index)$ext';
  }

  /// 断点续传决策（纯函数，供单测）：已有 .part 且服务器确认 Range
  /// （HTTP 206）才续传追加；服务器忽略 Range 返回 200 全量时必须整体
  /// 重写——dio.download 的默认 FileMode.write 是"打开即截断"，与
  /// Range 头组合会把 .part 截断后只写进后半段字节，rename 出损坏文件
  /// （文件存在、能过存在性校验，解码必错）。返回值为实际续传偏移。
  @visibleForTesting
  static int resolveResumeOffset({
    required int existingPartLength,
    required int statusCode,
  }) {
    if (existingPartLength <= 0) return 0;
    return statusCode == HttpStatus.partialContent ? existingPartLength : 0;
  }

  /// 流式下载到 .part，支持正确的断点续传（见 [resolveResumeOffset]）。
  @visibleForTesting
  static Future<void> downloadWithResume({
    required Dio dio,
    required String url,
    required String partPath,
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final partFile = File(partPath);
    final existingLength =
        partFile.existsSync() ? await partFile.length() : 0;

    final response = await dio.get<ResponseBody>(
      url,
      options: Options(
        responseType: ResponseType.stream,
        // 酷狗 CDN 校验 UA（与播放代理注入的一致），缺失会 403。
        headers: <String, dynamic>{
          HttpHeaders.userAgentHeader: AppConfig.kugouUserAgent,
          if (existingLength > 0)
            HttpHeaders.rangeHeader: 'bytes=$existingLength-',
        },
      ),
      cancelToken: cancelToken,
    );
    final body = response.data;
    if (body == null) {
      throw StateError('下载响应为空');
    }
    final startOffset = resolveResumeOffset(
      existingPartLength: existingLength,
      statusCode: response.statusCode ?? 0,
    );
    // 200（服务器忽略 Range）时整包重写；206 时在已有 .part 之后追加。
    final sink = partFile.openSync(
      mode: startOffset > 0 ? FileMode.append : FileMode.write,
    );
    var received = 0;
    // 206 的 contentLength 是"本次剩余字节数"，+startOffset 还原整包大小。
    final contentTotal = body.contentLength;
    // 期望总长：已知时用于截断校验。未知（-1）则跳过校验，保持旧行为。
    final expectedTotal = contentTotal >= 0 ? startOffset + contentTotal : null;
    try {
      await for (final chunk in body.stream) {
        sink.writeFromSync(chunk);
        received += chunk.length;
        onProgress?.call(
          startOffset + received,
          contentTotal >= 0 ? startOffset + contentTotal : 0,
        );
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    if (received == 0 && startOffset == 0) {
      throw StateError('下载内容为空');
    }
    // 截断校验：流“干净结束”但字节不足时不 rename，保留 .part 供续传。
    // 弱网/代理提前 FIN 即落在此分支，避免残缺文件被当完整落盘。
    if (expectedTotal != null && startOffset + received != expectedTotal) {
      throw StateError(
        '下载不完整：已收 ${startOffset + received}，期望 $expectedTotal，'
        '保留半成品供续传',
      );
    }
  }

  /// 在途任务 key 快照（清理时保留对应索引条目，任务结束会自己写回）。
  Set<String> get inFlightCacheKeys => Set.of(_cancelTokens.keys);

  /// 取消下载/缓存任务。
  Future<void> cancel(String cacheKey) async {
    final token = _cancelTokens[cacheKey];
    if (token != null && !token.isCancelled) {
      token.cancel();
    }
  }

  /// 删除文件（若存在）。
  Future<void> deleteFile(String path) async {
    final file = File(path);
    if (file.existsSync()) {
      await file.delete();
    }
  }

  /// 获取文件大小（字节），不存在返回 0。
  Future<int> fileSize(String path) async {
    final file = File(path);
    if (file.existsSync()) {
      return await file.length();
    }
    return 0;
  }

  /// 获取下载目录的总大小（字节）。
  Future<int> getDownloadDirSize() async {
    try {
      final dir = await downloadDir();
      if (!dir.existsSync()) return 0;
      var total = 0;
      for (final entity in dir.listSync(recursive: true)) {
        if (entity is File) {
          total += entity.lengthSync();
        }
      }
      return total;
    } catch (_) {
      return 0;
    }
  }

  /// 获取播放缓存目录的总大小（字节）。
  Future<int> getPlayCacheDirSize() async {
    try {
      final dir = await playCacheDir();
      if (!dir.existsSync()) return 0;
      var total = 0;
      for (final entity in dir.listSync(recursive: true)) {
        if (entity is File) {
          total += entity.lengthSync();
        }
      }
      return total;
    } catch (_) {
      return 0;
    }
  }

  /// 清空整个播放缓存目录。
  ///
  /// [excludePaths] 中的文件跳过（在播文件）；`.part` 半成品默认跳过——
  /// 在途任务结束会自己 rename，删了必失败；超过 24h 的孤儿 part（崩溃
  /// 残留）才顺手回收，避免无限堆积。
  Future<void> clearPlayCacheDir({Set<String> excludePaths = const {}}) async {
    final dir = await playCacheDir();
    if (!dir.existsSync()) return;
    final inFlightParts = Set.of(_partPaths.values);
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      final path = entity.path;
      if (excludePaths.contains(path)) continue;
      if (path.endsWith('.part')) {
        if (inFlightParts.contains(path)) continue;
        try {
          final stat = await entity.stat();
          if (DateTime.now().difference(stat.modified) <
              const Duration(hours: 24)) {
            continue;
          }
        } catch (_) {
          continue;
        }
      }
      try {
        await entity.delete();
      } catch (_) {}
    }
  }

  /// LRU 清理播放缓存至 [maxBytes]（默认 [AppConfig.playCacheMaxBytes]）以下。
  ///
  /// [entries] 为当前缓存索引（按 cachedAt 升序排列）。
  /// [excludePaths] 中的文件跳过清理（如正在播放的文件）。
  Future<void> prunePlayCache(
    List<({String cacheKey, String filePath, DateTime cachedAt})> entries, {
    int? maxBytes,
    Set<String> excludePaths = const {},
  }) async {
    int totalSize = 0;
    final fileSizes = <String, int>{};
    for (final entry in entries) {
      final size = await fileSize(entry.filePath);
      fileSizes[entry.filePath] = size;
      totalSize += size;
    }

    final limit = maxBytes ?? AppConfig.playCacheMaxBytes;
    if (limit < 0) return; // 小于 0 代表无限制
    if (totalSize <= limit) return;

    // 按 cachedAt 升序删除最旧条目
    final sorted = List.of(entries)
      ..sort((a, b) => a.cachedAt.compareTo(b.cachedAt));

    for (final entry in sorted) {
      if (totalSize <= limit) break;
      if (excludePaths.contains(entry.filePath)) continue;
      final size = fileSizes[entry.filePath] ?? 0;
      await deleteFile(entry.filePath);
      totalSize -= size;
    }
  }

  /// 关闭 Dio（应用退出时调用）。
  void dispose() {
    _dio.close();
  }
}
