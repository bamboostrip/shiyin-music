import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../config/app_config.dart';

/// 启动期 SharedPreferences 一次性瘦身（直接操作原始 JSON 文件）。
///
/// ## 背景
///
/// 本应用把可重建的数据缓存（每首歌的歌词、首页/歌单/专辑/电台 JSON）也存
/// 在 SharedPreferences 里。Windows 实现是纯 Dart 的：**每次 `setX` 都会把
/// 整个 map 重新 `json.encode` 并同步写盘**，文件涨到十几 MB 后单次写入就要
/// 数百毫秒（阻塞 UI 线程）。实测：18.3MB 的文件解码约 500ms、编码+写盘约
/// 550-600ms，启动阶段十几次写入会让界面卡十几秒。
///
/// ## 本服务做什么
///
/// 在**第一次访问 SharedPreferences 之前**（见 `LegacyMigration.run`）直接
/// 读写 `<应用支持目录>/shared_preferences.json`：
///
/// 1. 删除 `cache_lyric_*`：歌词缓存已迁到按歌曲 hash 独立文件的
///    `LyricCacheService`，prefs 里不再需要（这是 14MB 里的大头）；
/// 2. 按 [AppConfig.dataCachePrefixCaps] 对仍留在 prefs 的按条缓存做淘汰，
///    只保留每个前缀最新的 N 条（`cache_home` 等单条缓存不受影响）。
///
/// 只有文件超过 [compactThresholdBytes]（或小于阈值但仍残留旧版
/// `cache_lyric_*`）才触发；触发时一次解码 + 一次编码即可完成清理，之后
/// 启动只剩一次便宜的字符扫描。任何异常都静默降级（缓存丢了只是重新拉取，
/// 不影响功能）。
///
/// 注意：**必须在 `SharedPreferences.getInstance()` 之前执行**——插件首次
/// 读取后会把整张 map 缓存在内存里，之后再改文件只会被下一次写盘覆盖。
class PrefsCompaction {
  PrefsCompaction._();

  /// 插件默认文件名（shared_preferences_windows 的 `_defaultFileName`）。
  static const String prefsFileName = 'shared_preferences.json';

  /// 超过该大小才触发瘦身。正常 prefs（几十 KB ~ 1MB）直接跳过。
  static const int compactThresholdBytes = 4 * 1024 * 1024;

  /// 已迁出 prefs 的缓存前缀（剥掉插件 `flutter.` 前缀后比较）。
  static const String migratedLyricPrefix = 'cache_lyric_';

  /// 插件给所有 key 加的统一前缀。
  static const String _flutterPrefix = 'flutter.';

  /// 在第一次 `SharedPreferences.getInstance()` 之前调用。
  ///
  /// [overrideDir] 仅供单元测试注入临时目录；生产一律用应用支持目录。
  /// [thresholdBytes] 仅供单元测试放宽/收紧触发阈值。
  /// 返回瘦身结果（未触发 / 无需改动时返回 null）。
  static Future<PrefsCompactionResult?> runIfNeeded({
    Directory? overrideDir,
    int? thresholdBytes,
  }) async {
    final threshold = thresholdBytes ?? compactThresholdBytes;
    try {
      final dir = overrideDir ?? await getApplicationSupportDirectory();
      final file = File('${dir.path}${Platform.pathSeparator}$prefsFileName');
      if (!await file.exists()) return null;
      final originalBytes = await file.length();
      if (originalBytes < threshold) {
        // 小于阈值但可能残留旧版 `cache_lyric_*`（修复前存在 prefs 里的
        // 歌词缓存）：这类文件不会很大，但每次写盘都要白白重编码它们。
        // 先做一次便宜的字符扫描，命中才解码。
        final probe = await file.readAsString();
        if (!probe.contains(migratedLyricPrefix)) return null;
        final decoded = jsonDecode(probe);
        if (decoded is! Map<String, dynamic>) return null;
        return _apply(file, decoded, originalBytes);
      }

      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) return null;
      return _apply(file, decoded, originalBytes);
    } catch (error, stack) {
      debugPrint('[时音][prefs] 启动瘦身失败（已跳过）: $error\n$stack');
      return null;
    }
  }

  static Future<PrefsCompactionResult?> _apply(
    File file,
    Map<String, dynamic> decoded,
    int originalBytes,
  ) async {
    final result = plan(decoded);
    if (!result.changed) return null;

    // 先写临时文件再原子替换：中途崩溃时旧文件仍在，不会把设置写坏。
    final compactedText = jsonEncode(result.map);
    final tmp = File('${file.path}.compact.tmp');
    await tmp.writeAsString(compactedText, flush: true);
    await tmp.rename(file.path);

    debugPrint(
      '[时音][prefs] 启动瘦身完成: '
      '${(originalBytes / (1024 * 1024)).toStringAsFixed(1)}MB → '
      '${(compactedText.length / (1024 * 1024)).toStringAsFixed(1)}MB'
      '（删除歌词缓存 ${result.droppedLyricKeys} 条，'
      '淘汰条数超限 ${result.evictedCacheKeys} 条，'
      '淘汰总量超限 ${result.evictedForBudget} 条）',
    );
    return result;
  }

  /// 纯函数：计算瘦身后的 map（不改动入参）。
  ///
  /// 供 `LegacyMigration` 与单测共用，方便在没有文件 IO 的情况下验证规则。
  @visibleForTesting
  static PrefsCompactionResult plan(Map<String, dynamic> raw) {
    final result = Map<String, dynamic>.of(raw);
    var droppedLyricKeys = 0;

    // 1) 歌词缓存已迁到文件缓存，直接从 prefs 删除。
    for (final key in raw.keys) {
      if (_normalized(key).startsWith(migratedLyricPrefix)) {
        result.remove(key);
        droppedLyricKeys++;
      }
    }

    // 2) 其余按条缓存逐前缀做「保留最新 N 条」淘汰。
    //    key 归到最长匹配的前缀（cache_playlist_collection_ 不应被当成
    //    cache_playlist_），因此按前缀长度倒序匹配。
    final prefixes = AppConfig.dataCachePrefixCaps.keys.toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    final groups = <String, List<MapEntry<String, dynamic>>>{};
    for (final entry in result.entries) {
      final normalized = _normalized(entry.key);
      for (final prefix in prefixes) {
        if (normalized.startsWith(prefix)) {
          groups.putIfAbsent(prefix, () => <MapEntry<String, dynamic>>[]).add(entry);
          break;
        }
      }
    }

    var evictedCacheKeys = 0;
    for (final group in groups.entries) {
      final cap = AppConfig.dataCachePrefixCaps[group.key] ?? 0;
      if (cap <= 0 || group.value.length <= cap) continue;
      final sorted = List<MapEntry<String, dynamic>>.of(group.value)
        ..sort((a, b) => _savedAtOf(a.value).compareTo(_savedAtOf(b.value)));
      for (var i = 0; i < sorted.length - cap; i++) {
        result.remove(sorted[i].key);
        evictedCacheKeys++;
      }
    }

    // 3) 总量预算：条数没超但单条很大（超长歌单全量歌曲表、本地歌词匹配
    //    缓存）时，按 savedAt 从旧到新淘汰到预算内。
    var evictedForBudget = 0;
    var cacheChars = _cacheChars(result);
    final budget = AppConfig.dataCacheMaxChars;
    if (budget > 0 && cacheChars > budget) {
      final sorted = <MapEntry<String, dynamic>>[];
      for (final entry in result.entries) {
        if (!_isCacheKey(_normalized(entry.key))) continue;
        sorted.add(entry);
      }
      sorted.sort(
        (a, b) => _savedAtOf(a.value).compareTo(_savedAtOf(b.value)),
      );
      for (final entry in sorted) {
        if (cacheChars <= budget) break;
        final chars = entry.value is String ? (entry.value as String).length : 0;
        result.remove(entry.key);
        cacheChars -= chars;
        evictedForBudget++;
      }
    }

    return PrefsCompactionResult(
      map: result,
      droppedLyricKeys: droppedLyricKeys,
      evictedCacheKeys: evictedCacheKeys,
      evictedForBudget: evictedForBudget,
    );
  }

  /// 所有缓存值的字符数合计（JSON 以 ASCII 为主，近似字节数）。
  static int _cacheChars(Map<String, dynamic> map) {
    var total = 0;
    for (final entry in map.entries) {
      if (!_isCacheKey(_normalized(entry.key))) continue;
      final value = entry.value;
      if (value is String) total += value.length;
    }
    return total;
  }

  static bool _isCacheKey(String normalized) =>
      normalized.startsWith('cache_') ||
      normalized.startsWith('shiyin_cached_playlists');

  /// 剥掉插件的 `flutter.` 前缀，得到业务 key。
  static String _normalized(String key) => key.startsWith(_flutterPrefix)
      ? key.substring(_flutterPrefix.length)
      : key;

  /// 缓存条目的 savedAt（毫秒）。缓存值形如
  /// `{"savedAt": 1699999999999, "payload": ...}` 的 JSON 字符串；
  /// 解析不出来按 0 处理（视为最旧，优先被淘汰）。
  static int _savedAtOf(Object? value) {
    if (value is Map) return _asInt(value['savedAt']);
    if (value is! String) return 0;
    try {
      final decoded = jsonDecode(value);
      if (decoded is Map) return _asInt(decoded['savedAt']);
    } catch (_) {
      // 非 JSON 字符串（如旧格式/损坏条目）：按最旧处理。
    }
    return 0;
  }

  static int _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value) ?? 0;
    return 0;
  }
}

/// 瘦身结果（只读快照）。
class PrefsCompactionResult {
  const PrefsCompactionResult({
    required this.map,
    required this.droppedLyricKeys,
    required this.evictedCacheKeys,
    this.evictedForBudget = 0,
  });

  /// 瘦身后的完整 map（用于写回文件）。
  final Map<String, dynamic> map;

  /// 被删除的歌词缓存条数。
  final int droppedLyricKeys;

  /// 因超出单前缀条数上限被淘汰的缓存条数。
  final int evictedCacheKeys;

  /// 因超出总字符预算被淘汰的缓存条数。
  final int evictedForBudget;

  bool get changed =>
      droppedLyricKeys > 0 || evictedCacheKeys > 0 || evictedForBudget > 0;
}
