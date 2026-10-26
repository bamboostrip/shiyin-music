import 'dart:convert';
import 'dart:io';

import 'package:charset/charset.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../models/music_models.dart';
import 'cache_service.dart';
import 'local_song_matcher.dart';
import 'music_api.dart';

/// 本地歌曲歌词加载：同名 `.lrc` → 音频内嵌歌词 → 本地缓存 → 在线匹配缓存。
///
/// 移植自上游 kgka_Music_hl 3.2.0（`87c35a1`，含 `c60a92f` 的路径分隔符修复），
/// 按本 fork 的架构做了两处适配：
/// - **内嵌歌词改由 `embeddedLyricsReader` 注入**。上游直接用
///   `audio_metadata_reader` 读 ID3/Vorbis/MP4 标签，而本 fork 明确禁止引入该
///   依赖：内嵌歌词统一走 Rust `readLocalLyrics` / Android MethodChannel
///   （封装在 `LocalMusicController.getEmbeddedLyrics`，由播放控制器注入）。
/// - **缓存 key 用文件绝对路径的 SHA-1 稳定哈希**，不再把可能很长的本地路径
///   直接拼进 SharedPreferences 的 key。
///
/// 本地音乐（[SongSource.local]）大多数既没有 `.lrc` 也没有内嵌歌词，所以
/// 最后一步用元数据（歌手 + 歌名）在酷狗搜索同名歌曲，取匹配结果的 hash 拉
/// 在线歌词并缓存——本地文件不变就一直可用（离线也能显示上次匹配的歌词）。
///
/// 加载语义（与上游一致）：
/// - 空的/无效的 `.lrc` **不能**抑制内嵌或在线歌词；
/// - 只有纯文本（无时间轴）的内嵌歌词留作最后兜底，不阻断在线匹配；
/// - 全部来源失败返回空列表**不抛错**（无歌词优于阻断播放）；
/// - 失败结果不写缓存，下次播放会重试。
class LocalLyricsService {
  LocalLyricsService({
    required MusicApi api,
    CacheService? cache,
    Future<String?> Function(String path)? embeddedLyricsReader,
    Duration requestTimeout = _defaultRequestTimeout,
  }) : _api = api,
       _cache = cache,
       _embeddedLyricsReader = embeddedLyricsReader ?? _noEmbeddedLyrics,
       _requestTimeout = requestTimeout;

  final MusicApi _api;
  final CacheService? _cache;

  /// 读取音频文件内嵌歌词（原样返回：可能带 LRC 时间戳，也可能是不带时间的
  /// 纯文本）。默认实现返回 null，播放器侧应注入
  /// `localMusic.getEmbeddedLyrics`。
  final Future<String?> Function(String path) _embeddedLyricsReader;

  /// 搜索 / 拉歌词单请求超时。默认 10s（与上游一致）；允许注入是为了单测
  /// 能用几十毫秒验证超时降级，不必真等 10 秒。
  final Duration _requestTimeout;

  static const _defaultRequestTimeout = Duration(seconds: 10);

  /// `.lrc` 体积上限：2MB 以外的文件基本不是歌词（可能误命中同名音频或
  /// 日志），直接跳过，避免整读进内存。
  static const _maxSidecarBytes = 2 * 1024 * 1024;

  /// 在线匹配只尝试前 3 个通过加分的候选：更多只会放大误匹配/耗时。
  static const _maxCandidateAttempts = 3;

  /// 在线搜索结果条数（与上游一致）。
  static const _searchPageSize = 20;

  /// 进行中的加载（按本地文件路径去重）。并发 load 共享同一个 Future，
  /// 避免播放页兜底与切歌路径同时触发时重复搜索/重复拉歌词。
  final Map<String, Future<List<LyricLine>>> _inFlight = {};

  /// 加载 [song] 的歌词。[song] 应为本地歌曲（`id` 即文件绝对路径）。
  Future<List<LyricLine>> load(Song song) {
    final key = song.id;
    final running = _inFlight[key];
    if (running != null) {
      return running;
    }
    final future = _load(song);
    _inFlight[key] = future;
    // 成功/失败都要清登记：失败后重进播放页必须能重试，不能一直复用旧 Future。
    future.whenComplete(() => _inFlight.remove(key)).ignore();
    return future;
  }

  Future<List<LyricLine>> _load(Song song) async {
    // 1. 同名 .lrc：Linux/Android 区分大小写，两种扩展名都试。
    final sidecarLines = await _readSidecarLyrics(song.id);
    if (sidecarLines.isNotEmpty) {
      return sidecarLines;
    }

    // 2. 音频内嵌歌词：能解析出时间轴就直接用；只有纯文本时先留着做最后
    //    兜底（纯文本没有时间轴，优先尝试在线匹配拿到逐行时间轴）。
    String? plainEmbeddedLyrics;
    try {
      final embedded = await _embeddedLyricsReader(song.id);
      final lines = parseLyrics(embedded);
      if (lines.isNotEmpty) {
        return lines;
      }
      if (embedded != null && embedded.trim().isNotEmpty) {
        plainEmbeddedLyrics = embedded.trim();
      }
    } catch (error) {
      debugPrint('[时音][歌词] 读取本地内嵌歌词失败: $error');
    }

    // 3. 本地缓存：路径 + 文件签名都对上才算命中。
    final signature = await _signature(song);
    final cacheKey = _cacheKey(song.id);
    try {
      final cached = await _cache?.read<List<LyricLine>>(
        cacheKey,
        decode: (json) => json['signature'] == signature
            ? (json['lines'] as List? ?? const [])
                  .whereType<Map<String, dynamic>>()
                  .map(LyricLine.fromCache)
                  .toList()
            : const [],
        // TTL 只是 CacheService 的形状要求：本地文件不变就一直可用（与上游
        // 一致，实际忽略 TTL / isStale；文件替换靠上面的签名失配兜底）。
        ttl: const Duration(days: 30),
      );
      if (cached != null && cached.data.isNotEmpty) {
        return cached.data;
      }
    } catch (error) {
      debugPrint('[时音][歌词] 读取本地歌词缓存失败: $error');
    }

    // 4. 在线匹配：元数据搜索 → 同名匹配 → 逐个拉歌词，首个非空即缓存返回。
    final identity = LocalSongIdentity.fromSong(song);
    if (identity.isSearchable) {
      try {
        final results = await _api
            .searchSongs(identity.query, pageSize: _searchPageSize)
            .timeout(_requestTimeout);
        for (final candidate in identity.matchCandidates(results).take(
          _maxCandidateAttempts,
        )) {
          try {
            // 只把匹配到的酷狗 hash 交给歌词接口，绝不能拿本地路径当 hash。
            final lines = await _api.lyrics(candidate).timeout(_requestTimeout);
            if (lines.isEmpty) {
              continue;
            }
            await _writeCache(cacheKey, signature, candidate.hash, lines);
            return lines;
          } catch (error) {
            // 单个候选失败（无版权/VIP 限制/网络抖动）继续下一个。
            debugPrint('[时音][歌词] 拉取匹配候选歌词失败: $error');
          }
        }
      } catch (error) {
        // 搜索失败/超时静默：不影响播放，下次播放会重试。
        debugPrint('[时音][歌词] 本地歌曲在线匹配失败（静默降级）: $error');
      }
    }

    // 5. 纯文本内嵌歌词兜底：没有时间轴就按一整行展示，不臆造时间戳。
    return _plainLyricsFallback(plainEmbeddedLyrics);
  }

  /// 读同名 `.lrc`/`.LRC` 并解析；读失败/超限/解析为空都返回空列表，让调用方
  /// 继续尝试内嵌或在线歌词（空文件不能抑制后续来源）。
  Future<List<LyricLine>> _readSidecarLyrics(String audioPath) async {
    final dot = audioPath.lastIndexOf('.');
    final slash = audioPath.lastIndexOf(RegExp(r'[/\\]'));
    final stem = dot > slash ? audioPath.substring(0, dot) : audioPath;
    for (final extension in const ['.lrc', '.LRC']) {
      try {
        final sidecar = File('$stem$extension');
        if (!await sidecar.exists()) {
          continue;
        }
        if (await sidecar.length() > _maxSidecarBytes) {
          debugPrint('[时音][歌词] 跳过超过 2MB 的歌词文件: ${sidecar.path}');
          continue;
        }
        final content = decodeLocalLyricBytes(await sidecar.readAsBytes());
        final lines = parseLyrics(content);
        if (lines.isNotEmpty) {
          return lines;
        }
      } catch (error) {
        // 编码损坏/无权限等：记录后继续下一个来源。
        debugPrint('[时音][歌词] 读取同名 .lrc 失败: $error');
      }
    }
    return const [];
  }

  /// 缓存 signature：标题/歌手/时长 + 文件大小/修改时间。
  ///
  /// 文件替换、改名（路径变 → key 变）或元数据变化都会让缓存失配重新匹配；
  /// stat 失败（文件刚被移走）时用 0 占位，仍允许在线匹配，不阻断播放。
  Future<String> _signature(Song song) async {
    var fileSize = 0;
    var fileModifiedMs = 0;
    try {
      final stat = await File(song.id).stat();
      fileSize = stat.size;
      fileModifiedMs = stat.modified.millisecondsSinceEpoch;
    } catch (error) {
      debugPrint('[时音][歌词] 读取本地音频文件信息失败（按未知签名处理）: $error');
    }
    return jsonEncode([
      song.title,
      song.artist,
      song.duration?.inMilliseconds,
      fileSize,
      fileModifiedMs,
    ]);
  }

  /// 写缓存：`signature` 用于失效判定，`matchedHash` 记录匹配到的酷狗 hash
  /// （排查「这首本地歌为什么匹配到那首在线歌」时有用）。
  Future<void> _writeCache(
    String key,
    String signature,
    String matchedHash,
    List<LyricLine> lines,
  ) async {
    final cache = _cache;
    if (cache == null) {
      return;
    }
    try {
      await cache.write(key, {
        'signature': signature,
        'matchedHash': matchedHash,
        'lines': lines.map((line) => line.toCache()).toList(),
      });
    } catch (error) {
      // 写缓存失败只影响下次播放的命中率，不能影响本次歌词展示。
      debugPrint('[时音][歌词] 写入本地歌词缓存失败: $error');
    }
  }

  /// 缓存 key：`cache_local_lyric_v1_<文件绝对路径的 sha1>`。
  ///
  /// 不直接拿路径拼 key：本地路径可能很长且含盘符/反斜杠/空格，作为
  /// SharedPreferences key 既难看又可能超平台限制；sha1 对同一路径稳定，
  /// 不同路径碰撞概率可忽略。
  static String _cacheKey(String path) =>
      'cache_local_lyric_v1_${sha1.convert(utf8.encode(path))}';

  static List<LyricLine> _plainLyricsFallback(String? plainText) {
    if (plainText == null) {
      return const [];
    }
    return [LyricLine(time: Duration.zero, text: plainText)];
  }

  static Future<String?> _noEmbeddedLyrics(String path) async => null;
}

/// 解码本地 `.lrc` 字节流：UTF-16 BOM（LE/BE）→ UTF-8（严格）→ GBK 兜底。
///
/// 移植自上游 3.2.0。顺序很重要：
/// - UTF-16 必须靠 BOM 识别（旧中文歌词工具导出常见 UTF-16LE/BE）；
/// - UTF-8 用严格模式，非 UTF-8 的旧中文歌词（GBK）会抛 [FormatException]
///   后进入 GBK 分支，而不是显示一堆 U+FFFD 替换符；
/// - GBK 也用严格模式：真正损坏的文件继续抛错，让调用方跳过该 `.lrc`、
///   改走内嵌/在线歌词，而不是把乱码当歌词展示。
///
/// UTF-16 字节数为奇数说明文件被截断，抛 [FormatException]（与上游一致）。
String decodeLocalLyricBytes(List<int> bytes) {
  if (bytes.length >= 2 &&
      ((bytes[0] == 0xff && bytes[1] == 0xfe) ||
          (bytes[0] == 0xfe && bytes[1] == 0xff))) {
    if (bytes.length.isOdd) {
      throw const FormatException('Truncated UTF-16 lyric');
    }
    final littleEndian = bytes[0] == 0xff;
    return String.fromCharCodes([
      for (var i = 2; i + 1 < bytes.length; i += 2)
        littleEndian
            ? bytes[i] | (bytes[i + 1] << 8)
            : (bytes[i] << 8) | bytes[i + 1],
    ]);
  }
  try {
    return utf8.decode(bytes);
  } on FormatException {
    // 旧中文 LRC 常用 GBK；保持严格解码，真正损坏的文件继续抛错由上层跳过。
    return gbk.decode(bytes);
  }
}
