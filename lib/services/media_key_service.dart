import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 播控回调：原生媒体键最终要执行的播放动作。
typedef MediaKeyCallback = Future<void> Function();

/// 车机方向盘媒体键的前台兜底（issue #15）。
///
/// 背景：audio_service 的 MediaSession 已覆盖「后台 / 系统媒体会话」路径
/// （通知栏、锁屏、蓝牙 AVRCP 等）；但部分国产车机（如 Flyme Auto /
/// Android 11）把方向盘按键以 KeyEvent 直接派发给前台 Activity。
/// `AudioServiceActivity` 默认不消费这些键，表现为方控完全无效。
///
/// 原生侧（`CarMediaKeyHandler.kt`）在 `MainActivity.dispatchKeyEvent` 中
/// 识别标准媒体键，经 MethodChannel [channelName] 下发本类；本类只做
/// 「method 名 → 注入回调」的分发，不直接依赖 PlayerController，便于单测。
///
/// 只在 Android 注册（其他平台 no-op）；[detach] 可安全重复调用。
class MediaKeyService {
  MediaKeyService({
    @visibleForTesting MethodChannel? channel,
    @visibleForTesting bool? isAndroid,
  })  : _channel = channel ?? const MethodChannel(channelName),
        _isAndroid = isAndroid ?? defaultIsAndroid();

  /// 与 Android 侧 CarMediaKeyHandler.CHANNEL_NAME 保持一致。
  static const String channelName = 'shiyin_music/media_key';

  /// 原生下行的方法名（与 CarMediaKeyHandler 的 METHOD_* 一一对应）。
  static const String methodTogglePlay = 'togglePlay';
  static const String methodPlay = 'play';
  static const String methodPause = 'pause';
  static const String methodNext = 'next';
  static const String methodPrevious = 'previous';
  static const String methodStop = 'stop';

  /// 是否 Android 平台：只有 Android 需要注册原生媒体键兜底。
  ///
  /// `kIsWeb` 必须先短路：web 上访问 `Platform` 会直接抛异常。
  static bool defaultIsAndroid() => !kIsWeb && Platform.isAndroid;

  final MethodChannel _channel;
  final bool _isAndroid;
  final Map<String, MediaKeyCallback> _handlers = <String, MediaKeyCallback>{};
  bool _isAttached = false;

  /// 是否已注册原生回调（非 Android 或 detach 后为 false）。
  bool get isAttached => _isAttached;

  /// 当前平台是否支持媒体键兜底（仅 Android）。
  bool get isSupported => _isAndroid;

  /// 注册原生媒体键回调。
  ///
  /// 非 Android 平台 no-op；重复调用只更新回调，不重复注册消息处理器
  /// （防止两个 handler 叠加导致一次按键触发两次播控）。
  void attach({
    required MediaKeyCallback onTogglePlay,
    required MediaKeyCallback onPlay,
    required MediaKeyCallback onPause,
    required MediaKeyCallback onNext,
    required MediaKeyCallback onPrevious,
    required MediaKeyCallback onStop,
  }) {
    if (!_isAndroid) {
      return;
    }
    _handlers
      ..clear()
      ..addAll(<String, MediaKeyCallback>{
        methodTogglePlay: onTogglePlay,
        methodPlay: onPlay,
        methodPause: onPause,
        methodNext: onNext,
        methodPrevious: onPrevious,
        methodStop: onStop,
      });
    if (_isAttached) {
      return;
    }
    _isAttached = true;
    _channel.setMethodCallHandler(_handleMethodCall);
  }

  /// 摘除原生回调并清空注入的播控动作；重复调用 no-op。
  void detach() {
    if (!_isAttached) {
      return;
    }
    _isAttached = false;
    _handlers.clear();
    _channel.setMethodCallHandler(null);
  }

  /// 原生下行分发：未知 method 静默忽略，回调异常只记日志不外抛。
  Future<dynamic> _handleMethodCall(MethodCall call) async {
    if (!_isAttached) {
      return null;
    }
    final handler = _handlers[call.method];
    if (handler == null) {
      debugPrint('[MediaKey] 未知方法 ${call.method}（忽略）');
      return null;
    }
    try {
      await handler();
    } catch (error) {
      // 回调来自播放控制器等外部注入方：媒体键是用户输入，任何失败都
      // 不能变成未捕获异步异常，只记录。
      debugPrint('[MediaKey] 执行 ${call.method} 失败（忽略）: $error');
    }
    return null;
  }
}
