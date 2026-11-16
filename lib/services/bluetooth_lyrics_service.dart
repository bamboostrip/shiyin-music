import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'lrc_formatter.dart';

/// 车载蓝牙歌词服务。
///
/// 作用：
/// 1. 发送标准 Android 音乐广播（`com.android.music.metachanged` 等）并携带 `lyric` 字段，
///    大多数第三方车机歌词 App / DIY 中控 / Xposed 模块会监听这些广播并在车机屏显示歌词。
/// 2. 同时发送常见音乐 App（网易云、QQ 音乐、酷狗、酷我）的自定义 action，保证最大兼容性。
///
/// 仅在 Android 平台生效，非 Android 平台所有方法均为安全的 no-op。
class BluetoothLyricsService {
  static const _channel = MethodChannel('shiyin_music/bluetooth_lyrics');

  /// 整首 LRC 的长度上限（UTF-16 字符数）。
  ///
  /// 广播 extras 走 Binder 事务（约 1MB 上限），且行内心跳每秒重发一次；
  /// 超长有声书（数千行）会把每次广播撑到几十 KB，弱车机上还有
  /// TransactionTooLargeException 风险。超过上限时**不下发**整首 LRC：
  /// 截断的 LRC 本身就是乱码，宁可退回旧版的「只发当前行」行为。
  /// 常规歌曲的整首 LRC 约 2~4KB，远低于该阈值。
  static const maxFullLyricChars = 32 * 1024;

  /// 成功广播的日志签名去重。
  ///
  /// 行内心跳每秒一条、且诊断日志是 1000 条环形缓存（见 AppLogService），
  /// 按时长抽样仍会刷屏并挤掉更早的关键行。改为“签名变化才记”：每首歌最多
  /// 两条（首行、以及整首 LRC 就绪那一刻），足以判断「通道活着 + 整首 LRC
  /// 真的发出去了」，失败则一律即时打印。
  String? _lastLoggedSignature;

  static bool get isSupportedPlatform {
    return !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  }

  /// 截断到 [max] 字符，不切断代理对（emoji 歌词会把孤立高位代理留给日志
  /// 落盘的 UTF-8 编码器，那里会直接抛错）。
  static String clip(String text, int max) {
    if (text.length <= max) return text;
    var end = max;
    final unit = text.codeUnitAt(end - 1);
    if (unit >= 0xD800 && unit <= 0xDBFF) end -= 1;
    return text.substring(0, end);
  }

  /// 记录一次广播结果（进 Flutter 侧诊断日志，见 [broadcastMetaChanged]）。
  ///
  /// 车机端问题过去只能靠 `adb logcat -s BluetoothLyrics` 排查（车主多半
  /// 拿不到），而原生 `Log.d` 不会进应用内导出日志。这里把「发没发出去、
  /// 整首 LRC 多长、position 多少」一起落到 debugPrint，导出日志即可判断
  /// 广播通道是否活着（issue #22 二次排查）。
  void _logResult({
    required bool ok,
    required String title,
    required String lyric,
    required String fullLyric,
    required int positionMs,
    required bool playing,
  }) {
    final summary =
        'title="$title" lyric="${clip(lyric, 24)}" '
        'pos=${positionMs}ms playing=$playing fullLrcLen=${fullLyric.length}';
    if (!ok) {
      debugPrint('[BluetoothLyrics] 广播失败（原生层返回 false）：$summary');
      return;
    }
    final signature = '$title|${fullLyric.isNotEmpty}';
    if (signature == _lastLoggedSignature) return;
    _lastLoggedSignature = signature;
    debugPrint('[BluetoothLyrics] 广播成功：$summary');
  }

  /// 发送「歌曲/歌词变化」广播。
  ///
  /// 歌词行变化或切歌时调用；周期性位置心跳（见控制器侧节流）也复用本方法，
  /// 此时 [lyric] 为当前行、[fullLyric] 为整首 LRC。
  ///
  /// [fullLyric] 是整首歌的标准 LRC（`[mm:ss.xx]正文`，行间 `\n`）。车机端
  /// 主流做法是拿到整首 LRC 后按 [position] 自行滚动高亮；只发当前一行时
  /// 车机端既无法滚动，也容易把单行纯文本当 LRC 解析失败而渲染出乱码
  /// （issue #22）。为空时原生层省略该字段，保持与旧车机端 App 的兼容。
  ///
  /// [plainLyric] 是整首 LRC 剥掉时间标签后的纯文本：部分车机歌词槽只认
  /// 纯文本，见到 `[00:12.34]` 会原样显示成乱码。为空时原生层同样省略。
  Future<void> broadcastMetaChanged({
    required String title,
    required String artist,
    String? album,
    String? lyric,
    String? fullLyric,
    required Duration position,
    required Duration duration,
    required bool playing,
    required int trackIndex,
    required int listSize,
  }) async {
    if (!isSupportedPlatform) return;
    // 超长整首 LRC 直接省略（见 [maxFullLyricChars]）：截断即乱码。
    final full = (fullLyric != null && fullLyric.length <= maxFullLyricChars)
        ? fullLyric
        : '';
    final plain = LrcFormatter.toPlainText(full) ?? '';
    try {
      final ok =
          await _channel.invokeMethod<bool>('broadcastMetaChanged', {
            'title': title,
            'artist': artist,
            'album': album ?? '',
            'lyric': lyric ?? '',
            'fullLyric': full,
            'plainLyric': plain,
            'positionMs': position.inMilliseconds,
            'durationMs': duration.inMilliseconds,
            'playing': playing,
            'track': trackIndex,
            'listSize': listSize,
          }) ??
          // 原生层未回结果（老版本/通道降级）按成功处理：不改历史语义。
          true;
      _logResult(
        ok: ok,
        title: title,
        lyric: lyric ?? '',
        fullLyric: full,
        positionMs: position.inMilliseconds,
        playing: playing,
      );
    } on MissingPluginException {
      // 非 Android/未注册实现：静默（桌面端本来就没有车机广播）。
    } catch (e) {
      debugPrint('[BluetoothLyrics] 广播异常: $e');
    }
  }

  /// 发送「播放状态变化」广播（暂停/恢复/停止）。
  Future<void> broadcastPlayStateChanged({
    required String title,
    required String artist,
    String? album,
    required Duration position,
    required Duration duration,
    required bool playing,
  }) async {
    if (!isSupportedPlatform) return;
    try {
      await _channel.invokeMethod<void>('broadcastPlayStateChanged', {
        'title': title,
        'artist': artist,
        'album': album ?? '',
        'positionMs': position.inMilliseconds,
        'durationMs': duration.inMilliseconds,
        'playing': playing,
      });
    } on MissingPluginException {
      // ignore
    } catch (_) {
      // ignore
    }
  }
}
