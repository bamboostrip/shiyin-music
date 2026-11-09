import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

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

  static bool get isSupportedPlatform {
    return !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
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
    try {
      await _channel.invokeMethod<void>('broadcastMetaChanged', {
        'title': title,
        'artist': artist,
        'album': album ?? '',
        'lyric': lyric ?? '',
        'fullLyric': full,
        'positionMs': position.inMilliseconds,
        'durationMs': duration.inMilliseconds,
        'playing': playing,
        'track': trackIndex,
        'listSize': listSize,
      });
    } on MissingPluginException {
      // ignore
    } catch (_) {
      // ignore
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
