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
  static const _channel = MethodChannel('kgka_music_hl/bluetooth_lyrics');

  static bool get isSupportedPlatform {
    return !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  }

  /// 发送「歌曲/歌词变化」广播。
  ///
  /// 歌词行变化或切歌时调用。
  Future<void> broadcastMetaChanged({
    required String title,
    required String artist,
    String? album,
    String? lyric,
    required Duration position,
    required Duration duration,
    required bool playing,
    required int trackIndex,
    required int listSize,
  }) async {
    if (!isSupportedPlatform) return;
    try {
      await _channel.invokeMethod<void>('broadcastMetaChanged', {
        'title': title,
        'artist': artist,
        'album': album ?? '',
        'lyric': lyric ?? '',
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
