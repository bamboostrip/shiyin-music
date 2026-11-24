import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../src/rust/api.dart' as rust;
import 'local_audio_formats.dart';

/// 一次读取的三种结果：拿到字节 / 确定没有图（进负缓存）/ 读取失败
/// （瞬时态，不缓存——外接盘未挂载、通道异常都属此类）。
enum _ArtworkRead { bytes, none, failed }

/// 读取结果载体：[_ArtworkRead.bytes] 时 [bytes] 非空。
typedef _ArtworkOutcome = ({_ArtworkRead kind, Uint8List? bytes});

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
/// [artworkUrlFor]（`localart://<urlEncode(目标)>`），由 `Artwork` 识别后
/// 向本服务要字节——桌面走 Rust `readLocalCover`（symphonia 的 `visuals()`，
/// 支持 ID3v2 APIC / FLAC PICTURE / MP4 covr），Android 走 MethodChannel 的
/// `MediaMetadataRetriever.embeddedPicture`。
///
/// 「目标」可以是**文件路径**，也可以是 **`content://` 媒体库地址**：分区
/// 存储下裸路径不一定可读（Android 10 直接拒绝），Android 侧会优先把
/// content URI 传进来，MediaMetadataRetriever 两种都能吃。
///
/// 缓存策略：[load] 内置按字节预算的 LRU。它不只是省 IO——`Image.memory`
/// 的 [MemoryImage] 以「字节对象身份」作为 ImageCache 的 key，同一路径每次
/// 重新读盘都会产生新对象、把 ImageCache 撑成一条条互不复用的条目；LRU
/// 复用同一 `Uint8List` 实例后，同一封面在列表/播放页/锁屏之间共享同一条
/// 解码结果，滚动回来也不会再触发一次原生解析。
class LocalArtworkService {
  LocalArtworkService._();

  /// 伪 URL scheme。只在本进程内有效，**不得**直接下发给系统媒体会话
  /// （见 `SystemMediaArtResolver`）；要给通知栏/锁屏用，必须先经
  /// [systemArtUriFor] 落盘换成 `file://` URI。
  static const String scheme = 'localart';

  /// 系统媒体会话封面的落盘子目录（应用缓存目录下）。
  static const String systemArtDirName = 'localart';

  /// 落盘封面文件数上限。
  ///
  /// 每张是内嵌原图的原样字节（几百 KB 到数 MB），超出后按最近修改时间
  /// 淘汰最旧的：曲库大的用户长期使用也不会把缓存目录无限撑大。文件名由
  /// 读取目标哈希而来，被淘汰的歌再次播放时重新落盘即可。
  static const int _systemArtFileCap = 64;

  /// 测试注入：落盘目录的父目录（默认取应用缓存目录，依赖 path_provider
  /// 平台通道，单测里没有）。
  @visibleForTesting
  static Future<Directory> Function()? debugSystemArtRootOverride;

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
  /// 只记「确定无图」（解析成功无图）；读取失败（IO/权限/外接盘未挂载）
  /// 是瞬时态，不进负缓存。
  ///
  /// 没有负缓存时，无封面的本地歌每次滚动进视口都会重新 probe 一遍容器——
  /// 几百首的库里净是无关的读盘。上限取 4096 条：路径只是短字符串，占用
  /// 可忽略，且按插入顺序淘汰，不会无限增长。
  static final LinkedHashSet<String> _noArtwork = LinkedHashSet();
  static const int _noArtworkCap = 4096;

  /// 构造本地封面的伪 URL；[source] 可以是文件路径或 `content://` 地址。
  /// `Artwork` 据此走本地封面分支。
  static String artworkUrlFor(String source) =>
      '$scheme://${Uri.encodeComponent(source)}';

  /// 该 URL 是否为本服务的本地封面伪 URL。
  static bool isArtworkUrl(String? url) =>
      url != null && url.startsWith('$scheme://');

  /// 从伪 URL 还原读取目标（文件路径或 content URI）；不是本服务的 URL 时返回 null。
  static String? targetOf(String url) {
    final prefix = '$scheme://';
    if (!url.startsWith(prefix)) return null;
    try {
      final target = Uri.decodeComponent(url.substring(prefix.length));
      return target.isEmpty ? null : target;
    } catch (_) {
      return null;
    }
  }

  /// 读取内嵌封面字节；无图/读取失败一律返回 null（不抛）。区别在缓存：
  /// 无图进负缓存，读取失败是瞬时态不缓存，重进视口会重试。
  static Future<Uint8List?> load(String source) {
    final cached = _cache.remove(source);
    if (cached != null) {
      // 命中即刷新 LRU 位置（moveToEnd 语义）。
      _cache[source] = cached;
      return Future<Uint8List?>.value(cached);
    }
    if (_noArtwork.contains(source)) {
      return Future<Uint8List?>.value(null);
    }
    final running = _inFlight[source];
    if (running != null) return running;
    final future = _read(source);
    _inFlight[source] = future;
    return future.whenComplete(() => _inFlight.remove(source));
  }

  static Future<Uint8List?> _read(String source) async {
    final outcome = await _readPlatform(source);
    switch (outcome.kind) {
      case _ArtworkRead.bytes:
        _remember(source, outcome.bytes!);
        return outcome.bytes;
      case _ArtworkRead.none:
        _rememberMissing(source);
        return null;
      case _ArtworkRead.failed:
        return null; // 瞬时失败：不写任何缓存
    }
  }

  static Future<_ArtworkOutcome> _readPlatform(String source) async {
    final engine = currentLocalAudioEngine;
    // content:// 只有 Android 侧认得（Rust 只能开真实路径）。
    final isContentUri = source.startsWith('content://');
    try {
      if (engine == LocalAudioEngine.mpv && !isContentUri) {
        // Windows / Linux：Rust symphonia 读容器内嵌图。
        // Err(打不开) → failed（不缓存）；Ok(None) → none（确定无图）。
        final bytes = await rust.readLocalCover(path: source);
        return bytes == null || bytes.isEmpty
            ? (kind: _ArtworkRead.none, bytes: null)
            : (kind: _ArtworkRead.bytes, bytes: bytes);
      }
      if (engine == LocalAudioEngine.exoPlayer) {
        // Android：MMR.embeddedPicture；null=确定无图，异常=读取失败。
        final bytes = await _channel.invokeMethod<Uint8List>(
          'getEmbeddedCover',
          {'source': source},
        );
        return bytes == null || bytes.isEmpty
            ? (kind: _ArtworkRead.none, bytes: null)
            : (kind: _ArtworkRead.bytes, bytes: bytes);
      }
    } catch (error) {
      // 读取失败不进负缓存：外接盘慢挂载/瞬时 IO 错误后，挂载完成即可恢复。
      debugPrint('[时音][artwork] 读取本地封面失败(不缓存): $source ($error)');
      return (kind: _ArtworkRead.failed, bytes: null);
    }
    // avFoundation 等暂未接读取通道的平台：按无图处理（iOS/macOS 本地音乐扫描尚未支持，进负缓存无害）。
    return (kind: _ArtworkRead.none, bytes: null);
  }

  /// 把 [source] 的内嵌封面落到应用缓存目录，返回可交给系统媒体会话的
  /// `file://` URI（issue #34：本地文件在通知栏/锁屏不显示封面）。
  ///
  /// 为什么必须落盘：`localart://` 是进程内伪 URL，系统解析不了。audio_service
  /// 只认两类封面——`content://`（原生侧自行打开）和能变成文件的 URI；
  /// `file://` 会被它转成文件路径交给原生解码（Android 走 BitmapFactory，
  /// Windows SMTC / Linux MPRIS 直接读文件），全程是本进程自己的文件，
  /// 不需要跨进程授权，也不需要 FileProvider。
  ///
  /// 返回 null = 没有可下发的封面（确定无图 / 读取失败 / 写盘失败），调用方
  /// 按无图处理。结果不在这里缓存否定：下次仍会尝试，外接盘挂载后可自愈。
  static Future<Uri?> systemArtUriFor(String source) async {
    final bytes = await load(source);
    if (bytes == null || bytes.isEmpty) return null;
    final Directory base;
    try {
      base = await (debugSystemArtRootOverride ?? getTemporaryDirectory)();
    } catch (error) {
      debugPrint('[时音][artwork] 取缓存目录失败: $error');
      return null;
    }
    // 文件名 = 读取目标的哈希 + 按魔数识别的扩展名：同一个文件（无论按
    // 路径还是 content URI 读到）对应同一个落盘文件，重复播放直接命中。
    final target = File(
      '${base.path}/$systemArtDirName/'
      '${sha1.convert(utf8.encode(source))}'
      '.${imageExtensionForBytes(bytes) ?? 'img'}',
    );
    try {
      // 已落盘直接复用，不再写盘；顺手刷新修改时间，让淘汰始终淘汰
      // 「最久没听」的那张。触碰失败（只读卷等）不影响复用。
      if (await target.exists()) {
        try {
          await target.setLastModified(DateTime.now());
        } catch (_) {}
        return Uri.file(target.path);
      }
      await target.parent.create(recursive: true);
      // 先写临时文件再改名：改名在同一卷上是原子的，进程被杀也不会留下
      // 半个文件被下次当成「已落盘」直接交给系统（解码失败 → 这首歌永远
      // 没封面）。
      final temp = File('${target.path}.tmp');
      await temp.writeAsBytes(bytes, flush: true);
      await temp.rename(target.path);
    } catch (error) {
      debugPrint('[时音][artwork] 系统封面落盘失败: $source ($error)');
      return null;
    }
    // 淘汰同步等完：目录里最多 65 个文件，列目录 + stat 是毫秒级的事，
    // 换来的是「函数返回 = 落盘与清理都已收尾」，不留无人等待的后台 IO。
    await _trimSystemArtFiles(target.parent, keep: target);
    return Uri.file(target.path);
  }

  /// 按魔数判断图片格式的扩展名；认不出返回 null。
  ///
  /// 落盘文件要带对扩展名：Windows SMTC 按文件类型建缩略图流，Linux 桌面
  /// 的 MPRIS 封面加载也未必逐个嗅探内容。Android 的 BitmapFactory 不挑。
  @visibleForTesting
  static String? imageExtensionForBytes(List<int> bytes) {
    bool startsWith(List<int> magic, [int offset = 0]) {
      if (bytes.length < offset + magic.length) return false;
      for (var i = 0; i < magic.length; i++) {
        if (bytes[offset + i] != magic[i]) return false;
      }
      return true;
    }

    const jpeg = [0xFF, 0xD8, 0xFF];
    const png = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
    const riff = [0x52, 0x49, 0x46, 0x46];
    const webp = [0x57, 0x45, 0x42, 0x50];
    if (startsWith(jpeg)) return 'jpg';
    if (startsWith(png)) return 'png';
    if (startsWith(riff) && startsWith(webp, 8)) return 'webp';
    if (startsWith(const [0x47, 0x49, 0x46, 0x38])) return 'gif';
    if (startsWith(const [0x42, 0x4D])) return 'bmp';
    return null;
  }

  /// 落盘封面淘汰到 [_systemArtFileCap] 以内（按最近修改时间，越旧越先删），
  /// 顺带清掉进程被杀留下的 `.tmp` 残片。只是缓存，任何失败都只记日志。
  ///
  /// [keep] 是刚写的那张：修改时间粒度粗的文件系统上它可能与旧文件同刻，
  /// 排序后并不保证排在最前，必须点名豁免。
  static Future<void> _trimSystemArtFiles(
    Directory dir, {
    required File keep,
  }) async {
    try {
      final files = <File>[];
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is File) files.add(entity);
      }
      final excess = files.length - _systemArtFileCap;
      if (excess <= 0) return;
      final keptPath = keep.path;
      final stamped = <({File file, DateTime modified})>[];
      for (final file in files) {
        if (file.path == keptPath) continue;
        try {
          stamped.add((file: file, modified: await file.lastModified()));
        } catch (_) {
          // stat 不到的文件不动它（多半已被系统清掉）。
        }
      }
      stamped.sort((a, b) => a.modified.compareTo(b.modified));
      for (final entry in stamped.take(excess)) {
        try {
          await entry.file.delete();
        } catch (_) {}
      }
    } catch (error) {
      debugPrint('[时音][artwork] 清理落盘封面失败(忽略): $error');
    }
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
