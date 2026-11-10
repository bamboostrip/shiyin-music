import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:shared_preferences/shared_preferences.dart';

import '../config/app_config.dart';

/// 缓存读取结果。
class CacheResult<T> {
  const CacheResult({required this.data, required this.isStale});

  final T data;

  /// 是否已超过 TTL（过期）。
  final bool isStale;
}

/// 统一数据缓存服务。
///
/// 缓存载体为 SharedPreferences + JSON（决策1）。每条缓存存储为：
/// `{ "savedAt": <毫秒时间戳>, "payload": <任意 JSON> }`
///
/// 核心方法 [swr] 封装 stale-while-revalidate 模式：先返回缓存立即显示，
/// 后台静默刷新，失败时降级到缓存。该模式推广自 AuthController 已有的
/// 「先缓存后刷新 + 失败降级」逻辑。
class CacheService {
  CacheService();

  static const _savedAtKey = 'savedAt';
  static const _payloadKey = 'payload';

  // ===== key 命名规范 =====
  // 首页（匿名可访问，登出不清理）：cache_home
  // 歌单详情：cache_playlist_{playlistId}
  // 专辑详情：cache_album_{albumId}
  // 歌手详情：cache_artist_{artistId}
  // 用户信息：cache_user_{userId}
  // 用户歌单列表：cache_user_playlists_{userId}

  /// 用户相关缓存 key 前缀，登出时按前缀清理。
  static const _userCachePrefixes = <String>[
    'cache_user_',
    'cache_playlist_',
    'cache_album_',
    'cache_artist_',
  ];

  /// 读取缓存。无缓存返回 null。
  Future<CacheResult<T>?> read<T>(
    String key, {
    required T Function(Map<String, dynamic> json) decode,
    Duration ttl = const Duration(hours: 24),
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(key);
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      final payload = decoded[_payloadKey];
      if (payload is! Map<String, dynamic>) return null;
      final savedAt = decoded[_savedAtKey];
      final isStale = savedAt is! num ||
          DateTime.now().millisecondsSinceEpoch - savedAt.toInt() >
              ttl.inMilliseconds;
      return CacheResult<T>(data: decode(payload), isStale: isStale);
    } catch (error) {
      // 缓存损坏/结构变更按「无缓存」降级，但留日志：否则「离线为什么没
      // 兜底」无从排查。
      debugPrint('CacheService: 读取缓存 $key 失败（按无缓存处理）: $error');
      return null;
    }
  }

  /// 写入缓存（记录 savedAt = 当前时间）。
  ///
  /// 平台层写失败时 [SharedPreferences.setString] 返回 false 而不抛异常，
  /// 这里转为抛出，让调用方的 try/catch（及 swr 的「写失败不降级」分支）
  /// 能感知到，而不是静默丢写。
  ///
  /// 两个降低写盘开销的优化（Windows 上每次写 prefs 都会整文件 JSON
  /// 编码 + 同步写盘，文件大时单次数百毫秒）：
  /// - **payload 未变则不写**：启动时 SWR 刷新回来的数据常常和缓存一致，
  ///   跳过可省掉整次重写。但 `savedAt` 太久没刷新会让条目永远被判过期
  ///   （如歌单详情每次打开都全量重拉），因此超过
  ///   [AppConfig.cacheSavedAtRefreshAfter] 时仍写一次、只刷新 savedAt；
  /// - **按前缀限制条数**：超过 [AppConfig.dataCachePrefixCaps] 时从最旧
  ///   的条目开始淘汰，避免长期使用后 prefs 重新膨胀（每次最多淘汰几条，
  ///   避免历史积压一次性触发几十次整文件重写）。
  Future<void> write(String key, Map<String, dynamic> payload) async {
    final prefs = await SharedPreferences.getInstance();
    final existingRaw = prefs.getString(key);
    if (existingRaw != null && _hasSamePayload(existingRaw, payload)) {
      final now = DateTime.now().millisecondsSinceEpoch;
      final savedAt = _savedAtOf(existingRaw);
      final validatedRecently =
          now - savedAt < AppConfig.cacheSavedAtRefreshAfter.inMilliseconds;
      if (validatedRecently) return; // 内容一致且刚校验过：整次写盘都可以省掉
    }
    final wrapper = jsonEncode({
      _savedAtKey: DateTime.now().millisecondsSinceEpoch,
      _payloadKey: payload,
    });
    if (wrapper.length > AppConfig.dataCacheMaxEntryChars) {
      // 单条过大（如超长歌单的全量歌曲表）：宁可不缓存，也不让一个 key
      // 把 prefs 撑到需要整文件重编码的体量。
      debugPrint(
        'CacheService: 跳过超大缓存 key=$key（${wrapper.length} 字符，'
        '上限 ${AppConfig.dataCacheMaxEntryChars}）',
      );
      return;
    }
    final ok = await prefs.setString(key, wrapper);
    if (!ok) {
      throw Exception('CacheService: 写入缓存 $key 失败（平台层 setString 返回 false）');
    }
    await _enforcePrefixCap(prefs, key);
  }

  /// 已有缓存与待写 payload 是否完全一致（JSON 编码比较，键序稳定）。
  static bool _hasSamePayload(String raw, Map<String, dynamic> payload) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return false;
      final existing = decoded[_payloadKey];
      if (existing is! Map<String, dynamic>) return false;
      return jsonEncode(existing) == jsonEncode(payload);
    } catch (_) {
      // 损坏缓存按"不一致"处理，正常覆盖修复。
      return false;
    }
  }

  /// 对按条缓存的 key 做「保留最新 N 条」淘汰（N 见
  /// [AppConfig.dataCachePrefixCaps]，取最长匹配前缀）。
  ///
  /// 每次最多淘汰 [AppConfig.dataCacheEvictionsPerWrite] 条：历史积压
  /// （升级前条目远超新上限）不能一次性触发几十次整文件重写，那正是本次
  /// 要消灭的卡顿来源。积压会随多次缓存写入逐步收敛。
  Future<void> _enforcePrefixCap(
    SharedPreferences prefs,
    String key,
  ) async {
    final matchedPrefix = _capPrefixFor(key);
    if (matchedPrefix == null) return;
    final cap = AppConfig.dataCachePrefixCaps[matchedPrefix]!;
    if (cap <= 0) return;

    // 候选只算「同属这个前缀组」的 key：cache_playlist_ 与
    // cache_playlist_collection_ 是两组独立上限，不能互相挤占。
    final candidates = <String, int>{};
    for (final other in prefs.getKeys()) {
      if (other == key) continue;
      if (_capPrefixFor(other) != matchedPrefix) continue;
      final raw = prefs.getString(other);
      candidates[other] = raw == null ? 0 : _savedAtOf(raw);
    }
    // 新写入的这条算最新（savedAt = now），只需淘汰溢出的旧条目。
    final overflow = candidates.length + 1 - cap;
    if (overflow <= 0) return;
    final sorted = candidates.entries.toList()
      ..sort((a, b) => a.value.compareTo(b.value));
    final limit = math.min(
      overflow,
      AppConfig.dataCacheEvictionsPerWrite,
    );
    for (var i = 0; i < limit && i < sorted.length; i++) {
      await prefs.remove(sorted[i].key);
    }
  }

  /// key 命中的最长上限前缀（[AppConfig.dataCachePrefixCaps]）。
  static String? _capPrefixFor(String key) {
    String? matched;
    for (final prefix in AppConfig.dataCachePrefixCaps.keys) {
      if (!key.startsWith(prefix)) continue;
      if (matched == null || prefix.length > matched.length) {
        matched = prefix;
      }
    }
    return matched;
  }

  /// 解析缓存条目的 savedAt；解析不出来按 0（最旧）处理。
  static int _savedAtOf(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        final savedAt = decoded[_savedAtKey];
        if (savedAt is num) return savedAt.toInt();
      }
    } catch (_) {}
    return 0;
  }

  /// 移除单条缓存。
  Future<void> remove(String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(key);
  }

  /// 登出清理：清除用户相关缓存，保留匿名可访问内容（首页 cache_home）。
  Future<void> clearUserCache(String? userId) async {
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys().toList();
    for (final key in keys) {
      for (final prefix in _userCachePrefixes) {
        if (key.startsWith(prefix)) {
          await prefs.remove(key);
          break;
        }
      }
    }
  }

  /// 歌单缓存旧版双写 key 前缀（auth_controller 兼容写，仍在读取）：
  /// 与 `cache_*` 一样是可重建的缓存，计入大小统计，也必须随
  /// 「清理数据缓存」一并清除——否则清理后提示成功但大小几乎不变。
  static const _legacyPlaylistCachePrefix = 'shiyin_cached_playlists';

  /// 获取所有数据缓存的总大小（字节）。
  ///
  /// 遍历 SharedPreferences 中的所有 key，计算以 `cache_` 开头或
  /// 歌单缓存相关 key 的字符串大小（UTF-16 每字符约 2 字节）。
  Future<int> getCacheSize() async {
    final prefs = await SharedPreferences.getInstance();
    var total = 0;
    for (final key in prefs.getKeys()) {
      if (key.startsWith('cache_') ||
          key.startsWith(_legacyPlaylistCachePrefix)) {
        final value = prefs.getString(key);
        if (value != null) {
          total += value.length * 2; // UTF-16 每字符约 2 字节
        }
      }
    }
    return total;
  }

  /// 获取缓存条目数量。
  Future<int> getCacheCount() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs
        .getKeys()
        .where(
          (key) =>
              key.startsWith('cache_') ||
              key.startsWith(_legacyPlaylistCachePrefix),
        )
        .length;
  }

  /// 清除所有数据缓存（保留用户歌单索引等必要数据）。
  Future<void> clearAllCache() async {
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys().toList();
    for (final key in keys) {
      if (key.startsWith('cache_') ||
          key.startsWith(_legacyPlaylistCachePrefix)) {
        await prefs.remove(key);
      }
    }
  }

  /// stale-while-revalidate 封装。
  ///
  /// 流程：
  /// 1. 读取缓存 → 若命中，立即 [onData](cached)（首屏优先显示，无感）。
  /// 2. 后台执行 [fetch]：
  ///    - 成功 → [write] 缓存 → [onData](fresh)（静默刷新界面）。
  ///    - 失败 → 若缓存存在（哪怕过期）则保持不报错（降级）；
  ///      若完全无缓存则调用 [onError]。
  /// 3. [forceRefresh] = true（下拉刷新）时跳过第 1 步的立即返回，
  ///    优先走 fetch，失败再回退缓存。
  Future<void> swr<T>({
    required String key,
    required Duration ttl,
    required Future<T> Function() fetch,
    required T Function(Map<String, dynamic> json) decode,
    required Map<String, dynamic> Function(T data) encode,
    required void Function(T data) onData,
    void Function(Object error)? onError,
    bool forceRefresh = false,
  }) async {
    // 1. 先读缓存（非强制刷新时立即返回显示）
    CacheResult<T>? cached;
    if (!forceRefresh) {
      cached = await read<T>(key, decode: decode, ttl: ttl);
      if (cached != null) {
        onData(cached.data);
      }
    } else {
      // 强制刷新也先读缓存作为降级兜底，但不立即显示
      cached = await read<T>(key, decode: decode, ttl: ttl);
    }

    // 2. 后台静默刷新
    try {
      final fresh = await fetch();
      // 写缓存失败只记录，不作为本次刷新失败：新数据照常上屏，
      // 否则"拿到新数据却当失败降级显示旧缓存"。
      try {
        await write(key, encode(fresh));
      } catch (writeError) {
        debugPrint('CacheService: swr 写缓存失败 key=$key: $writeError');
      }
      onData(fresh);
    } catch (error) {
      if (cached != null) {
        // 有缓存（哪怕过期）则降级，不报错
        if (forceRefresh) {
          // 强制刷新模式下前面没有立即显示，这里补显示缓存
          onData(cached.data);
        }
      } else {
        // 完全无缓存，回调错误
        onError?.call(error);
      }
    }
  }
}
