import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../src/rust/api.dart' as rust;
import 'local_audio_formats.dart';

/// 本地音乐封面（音频文件内嵌图片）读取。
///
/// 为什么需要它（issue #32）：
/// - 桌面端扫描结果里 `coverUrl` 一直是 null——Rust 扫描只读标题/歌手/专辑，
///   从不取图，所以本地歌在列表/播放页恒为「音符」占位；
/// - Android 端此前用的是 `content://media/external/audio/albumart/<albumId>`，
///   这个 provider URI 自 Android 10 起已被移除，`openInputStream` 直接抛
///   FileNotFoundException，表现同样是「本地歌没有封面」。
///
/// 统一方案：把本地歌的 `coverUrl` 表示成进程内的伪 URL
/// [artworkUrlFor]（`localart://art/<urlEncode(path)>`），由 `Artwork`
/// 识别后向本服务要字节——桌面走 Rust `readLocalCover`（symphonia 的
/// `visuals()`，支持 ID3v2 APIC / FLAC PICTURE / MP4 covr），Android 走
/// MethodChannel 的 `MediaMetadataRetriever.embeddedPicture`。
///
/// 缓存策略：[load] 内置按字节预算的 LRU。它不只是省 IO——`Image.memory`
/// 的 [MemoryImage] 以「字节对象身份」作为 ImageCache 的 key，同一路径每次
/// 重新读盘都会产生新对象、把 ImageCache 撑成一条条互不复用的条目；LRU
/// 复用同一 `Uint8List` 实例后，同一封面在列表/播放页/锁屏之间共享同一条
/// 解码结果，滚动回来也不会再触发一次原生解析。
class LocalArtworkService {
  LocalArtworkService._();

  /// 伪 URL scheme。只在本进程内有效，**不得**下发给系统媒体会话
  /// （见 `MusicAudioHandler._mediaItemFor` 的过滤）。
  static const String scheme = 'localart';

  static const MethodChannel _channel = MethodChannel(
    'shiyin_music/local_music',
  );

  /// 进程内缓存：`path -> 原始图片字节`，插入顺序即 LRU 顺序。
  static final LinkedHashMap<String, Uint8List> _cache = LinkedHashMap();
  static int _cachedBytes = 0;

  /// 缓存字节预算。封面原图多在 100~600KB，12MB 约等于 30~100 张；
  /// 车机内存受限，不再上调（解码后的位图由 Flutter ImageCache 单独限额）。
  static const int _cacheBudgetBytes = 12 * 1024 * 1024;

  /// 单张超过该大小的图不进程内缓存：多半是 4K 扫描件级别的怪图，
  /// 留着只会把正常封面挤出去。
  static const int _maxEntryBytes = 3 * 1024 * 1024;

  /// 在途请求去重：同一路径并发命中（列表 + 迷你播放器 + 播放页同帧构建）
  /// 只解析一次。
  static final Map<String, Future<Uint8List?>> _inFlight = {};

  /// 「这个文件确实没有内嵌封面」的负缓存。
  ///
  /// 没有负缓存时，无封面的本地歌每次滚动进视口都会重新 probe 一遍容器——
  /// 几百首的库里净是无关的读盘。上限取 4096 条：路径只是短字符串，占用
  /// 可忽略，且按插入顺序淘汰，不会无限增长。
  static final LinkedHashSet<String> _noArtwork = LinkedHashSet();
  static const int _noArtworkCap = 4096;

  /// 构造某本地音频文件的封面伪 URL；`Artwork` 据此走本地封面分支。
  static String artworkUrlFor(String filePath) =>
      '$scheme://art/${Uri.encodeComponent(filePath)}';

  /// 该 URL 是否为本服务的本地封面伪 URL。
  static bool isArtworkUrl(String? url) =>
      url != null && url.startsWith('$scheme://');

  /// 从伪 URL 还原文件绝对路径；不是本服务的 URL 时返回 null。
  static String? pathOf(String url) {
    final prefix = '$scheme://art/';
    if (!url.startsWith(prefix)) return null;
    try {
      return Uri.decodeComponent(url.substring(prefix.length));
    } catch (_) {
      return null;
    }
  }

  /// 读取内嵌封面字节；无图/平台不支持/解析失败一律返回 null（不抛）。
  static Future<Uint8List?> load(String filePath) {
    final cached = _cache.remove(filePath);
    if (cached != null) {
      // 命中即刷新 LRU 位置（moveToEnd 语义）。
      _cache[filePath] = cached;
      return Future<Uint8List?>.value(cached);
    }
    if (_noArtwork.contains(filePath)) {
      return Future<Uint8List?>.value(null);
    }
    final running = _inFlight[filePath];
    if (running != null) return running;
    final future = _read(filePath);
    _inFlight[filePath] = future;
    return future.whenComplete(() => _inFlight.remove(filePath));
  }

  static Future<Uint8List?> _read(String filePath) async {
    final bytes = await _readPlatform(filePath);
    if (bytes == null || bytes.isEmpty) {
      _rememberMissing(filePath);
      return null;
    }
    _remember(filePath, bytes);
    return bytes;
  }

  static Future<Uint8List?> _readPlatform(String filePath) async {
    final engine = currentLocalAudioEngine;
    try {
      if (engine == LocalAudioEngine.mpv) {
        // Windows / Linux：Rust symphonia 读容器内嵌图。
        return await rust.readLocalCover(path: filePath);
      }
      if (engine == LocalAudioEngine.exoPlayer) {
        // Android：MediaMetadataRetriever.getEmbeddedPicture 覆盖面最广
        // （ID3v2 APIC / FLAC PICTURE / MP4 covr 都能取）。
        return await _channel.invokeMethod<Uint8List>('getEmbeddedCover', {
          'filePath': filePath,
        });
      }
    } catch (error) {
      // 读图失败绝不外溢：封面缺失只该是占位图，不该影响列表/播放。
      debugPrint('[时音][artwork] 读取本地封面失败: $filePath ($error)');
    }
    return null;
  }

  static void _remember(String filePath, Uint8List bytes) {
    _noArtwork.remove(filePath);
    if (bytes.length > _maxEntryBytes) return;
    final previous = _cache.remove(filePath);
    if (previous != null) _cachedBytes -= previous.length;
    _cache[filePath] = bytes;
    _cachedBytes += bytes.length;
    while (_cachedBytes > _cacheBudgetBytes && _cache.isNotEmpty) {
      final oldestKey = _cache.keys.first;
      final removed = _cache.remove(oldestKey)!;
      _cachedBytes -= removed.length;
    }
  }

  static void _rememberMissing(String filePath) {
    _cache.remove(filePath);
    _noArtwork.add(filePath);
    while (_noArtwork.length > _noArtworkCap) {
      _noArtwork.remove(_noArtwork.first);
    }
  }

  /// 仅供测试：清空缓存与在途登记，避免用例之间互相污染。
  static void debugReset() {
    _cache.clear();
    _cachedBytes = 0;
    _inFlight.clear();
    _noArtwork.clear();
  }

  /// 仅供测试：当前缓存条目数与占用字节。
  static ({int entries, int bytes}) get debugCacheStats =>
      (entries: _cache.length, bytes: _cachedBytes);

  /// 仅供测试：负缓存条目数。
  static int get debugMissingEntries => _noArtwork.length;
}
