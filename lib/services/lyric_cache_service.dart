import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../config/app_config.dart';
import '../models/song.dart';

/// 歌词磁盘缓存：**每首歌一个独立 JSON 文件，不再写 SharedPreferences**。
///
/// ## 为什么
///
/// 历史实现把每首歌的歌词写进 SharedPreferences 的 `cache_lyric_<hash>`，
/// 1000 首歌就是 10+MB；Windows 的 prefs 实现每次写入都要把整个 JSON
/// 重新编码并同步写盘（十几 MB 时单次数百毫秒、阻塞 UI），启动与切歌都会
/// 卡顿（详见 `PrefsCompaction` 的说明）。歌词是纯可重建缓存，天然适合
/// 按条独立存储。
///
/// ## 规则
///
/// - 位置：`<应用支持目录>/lyric_cache/<songHash>.json`；
/// - 格式：`{"savedAt": <毫秒>, "lines": [LyricLine.toCache(), ...]}`；
/// - 容量：总量超过 [AppConfig.lyricCacheMaxBytes] 时，启动裁剪按「最后
///   访问时间」从旧到新删除到 80%；超过 TTL 的条目直接删除；
/// - 所有 IO 失败静默降级（缓存丢了只是重新拉取，不影响播放）。
class LyricCacheService {
  LyricCacheService._();

  static final LyricCacheService instance = LyricCacheService._();

  /// 上限（字节）；[configure] 传入 <=0 表示关闭（测试/未初始化时不落盘）。
  int _maxBytes = 0;
  bool _disabled = false;
  Directory? _dir;
  Future<void>? _pruneFuture;

  /// 是否启用（已配置上限且目录可用）。
  bool get enabled => !_disabled && _maxBytes > 0;

  int get maxBytes => _maxBytes;

  /// 配置上限。同步、不做任何 IO，可在启动早期调用；目录按需惰性创建。
  void configure(int maxBytes) {
    _maxBytes = maxBytes;
    if (maxBytes <= 0) _disabled = true;
  }

  /// 仅供测试：注入临时目录，避免触碰真实用户目录。
  @visibleForTesting
  void debugOverrideDirectory(Directory? dir) {
    _dir = dir;
  }

  /// 仅供测试：重置状态，避免用例之间互相污染。
  @visibleForTesting
  void debugReset() {
    _maxBytes = 0;
    _disabled = false;
    _dir = null;
    _pruneFuture = null;
  }

  /// 读取某首歌的歌词缓存；不存在/损坏/已禁用时返回 null。
  Future<List<LyricLine>?> read(String hash) async {
    final file = await _fileFor(hash);
    if (file == null) return null;
    try {
      if (!await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return null;
      final rawLines = decoded['lines'];
      if (rawLines is! List) return null;
      final lines = rawLines
          .whereType<Map>()
          .map((e) => LyricLine.fromCache(Map<String, dynamic>.from(e)))
          .toList();
      if (lines.isEmpty) return null;
      // 记录"最后访问时间"供 LRU 裁剪：1 天内的重复读不再重复 touch，
      // 避免每次加载歌词都多一次写盘。
      final modified = (await file.stat()).modified;
      if (DateTime.now().difference(modified).inDays >= 1) {
        unawaited(
          file.setLastModified(DateTime.now()).catchError((_) => file),
        );
      }
      return lines;
    } catch (error) {
      debugPrint('[时音][lyric-cache] 读取失败（忽略）hash=$hash: $error');
      return null;
    }
  }

  /// 写入某首歌的歌词缓存（覆盖）。
  Future<void> write(String hash, List<LyricLine> lines) async {
    if (lines.isEmpty) return;
    final file = await _fileFor(hash);
    if (file == null) return;
    try {
      final payload = <String, dynamic>{
        'savedAt': DateTime.now().millisecondsSinceEpoch,
        'lines': lines.map((line) => line.toCache()).toList(),
      };
      await file.writeAsString(jsonEncode(payload), flush: true);
    } catch (error) {
      debugPrint('[时音][lyric-cache] 写入失败（忽略）hash=$hash: $error');
    }
  }

  /// 缓存总字节数（"清理数据缓存"展示用）。
  Future<int> totalBytes() async {
    final dir = await _ensureDir();
    if (dir == null) return 0;
    var total = 0;
    try {
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is File) {
          try {
            total += await entity.length();
          } catch (_) {}
        }
      }
    } catch (_) {}
    return total;
  }

  /// 缓存条目数。
  Future<int> count() async {
    final dir = await _ensureDir();
    if (dir == null) return 0;
    var count = 0;
    try {
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is File && entity.path.endsWith('.json')) count++;
      }
    } catch (_) {}
    return count;
  }

  /// 清空全部歌词缓存（设置页「清理数据缓存」）。
  Future<void> clear() async {
    final dir = await _ensureDir();
    if (dir == null) return;
    try {
      await for (final entity in dir.list(followLinks: false)) {
        try {
          await entity.delete(recursive: true);
        } catch (_) {}
      }
    } catch (error) {
      debugPrint('[时音][lyric-cache] 清空失败（忽略）: $error');
    }
  }

  /// 启动后裁剪（首帧后调用，避免拖慢冷启动）：先删过期，再按容量淘汰。
  ///
  /// 同一个 Future 复用，避免并发裁剪互相删到对方正在读的文件。
  Future<void> prune() {
    final running = _pruneFuture;
    if (running != null) return running;
    final future = _pruneNow();
    _pruneFuture = future;
    return future.whenComplete(() => _pruneFuture = null);
  }

  Future<void> _pruneNow() async {
    final dir = await _ensureDir();
    if (dir == null) return;
    try {
      final now = DateTime.now();
      final entries = <({File file, int size, DateTime modified})>[];
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File) continue;
        final name = entity.path.split(Platform.pathSeparator).last;
        // 写盘中断留下的临时文件/杂物直接清掉。
        if (name.startsWith('.') || name.endsWith('.tmp')) {
          try {
            await entity.delete();
          } catch (_) {}
          continue;
        }
        if (!name.endsWith('.json')) continue;
        try {
          final stat = await entity.stat();
          if (now.difference(stat.modified) > AppConfig.lyricCacheTtl) {
            await entity.delete();
            continue;
          }
          entries.add((file: entity, size: stat.size, modified: stat.modified));
        } catch (_) {}
      }
      var total = entries.fold<int>(0, (sum, entry) => sum + entry.size);
      final limit = _maxBytes;
      if (limit <= 0 || total <= limit) return;
      // 按最后访问时间从旧到新淘汰到上限的 80%，留出后续增长空间。
      entries.sort((a, b) => a.modified.compareTo(b.modified));
      final target = (limit * 0.8).round();
      var removed = 0;
      for (final entry in entries) {
        if (total <= target) break;
        try {
          await entry.file.delete();
          total -= entry.size;
          removed++;
        } catch (_) {}
      }
      if (removed > 0) {
        debugPrint(
          '[时音][lyric-cache] 容量裁剪：删除 $removed 条，'
          '剩余 ${(total / (1024 * 1024)).toStringAsFixed(1)}MB',
        );
      }
    } catch (error) {
      debugPrint('[时音][lyric-cache] 裁剪失败（忽略）: $error');
    }
  }

  Future<File?> _fileFor(String hash) async {
    if (!_isSafeHash(hash)) return null;
    final dir = await _ensureDir();
    if (dir == null) return null;
    return File('${dir.path}${Platform.pathSeparator}$hash.json');
  }

  Future<Directory?> _ensureDir() async {
    if (_disabled || _maxBytes <= 0) return null;
    final cached = _dir;
    if (cached != null) return cached;
    try {
      final support = await getApplicationSupportDirectory();
      final dir = Directory(
        '${support.path}${Platform.pathSeparator}${AppConfig.lyricCacheDirName}',
      );
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      _dir = dir;
      return dir;
    } catch (error) {
      // 拿不到目录就彻底关闭，避免每次加载歌词都重试一遍。
      _disabled = true;
      debugPrint('[时音][lyric-cache] 初始化目录失败（本次会话关闭）: $error');
      return null;
    }
  }

  /// hash 直接拼进文件名，只允许安全字符，杜绝目录穿越。
  static bool _isSafeHash(String hash) =>
      RegExp(r'^[0-9A-Za-z_-]{1,64}$').hasMatch(hash);
}
