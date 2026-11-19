import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'app_log_service.dart';

/// 车机媒体中心控制回调：方向盘/扶手箱按键最终要执行的播放动作。
typedef CarMediaCenterControlCallback = Future<void> Function();

/// 外部播控指令去重闸门（issue #15）。
///
/// 背景：EAS 媒体中心回调与 audio_service 的 MediaSession 路径（通知栏/
/// 蓝牙 AVRCP/系统媒体键）理论上可能对同一次按键双触发——一次按「下一首」
/// 跳两首。三个外部输入源（transportControls / 媒体键兜底 / 媒体中心）
/// 共用本闸门：同一动作在 [window] 内只放行第一次。
///
/// 窗口取 300ms：双通道转发通常在几十毫秒内先后到达；人类连按方向盘/
/// 通知栏两次的间隔一般远大于此，真实双击不受影响。
class CarMediaControlGate {
  CarMediaControlGate({
    this.window = const Duration(milliseconds: 300),
    DateTime Function()? now,
  }) : _now = now ?? (() => DateTime.now());

  /// 同动作去重窗口。
  final Duration window;

  final DateTime Function() _now;
  final Map<String, DateTime> _lastRunAt = <String, DateTime>{};

  /// 是否放行本次动作（窗口内重复返回 false）。
  bool shouldRun(String action) {
    final timestamp = _now();
    final last = _lastRunAt[action];
    if (last != null && timestamp.difference(last) < window) {
      return false;
    }
    _lastRunAt[action] = timestamp;
    return true;
  }

  /// 测试/重置用。
  @visibleForTesting
  void reset() => _lastRunAt.clear();
}

/// Flyme Auto（ECARX）媒体中心接入的 Dart 侧（issue #15）。
///
/// 背景：Flyme Auto 的方向盘按键由私有 EAS 媒体中心经 Binder 回调下发
/// （原生侧 mediacenter 包），标准 KeyEvent/MediaSession 路径收不到。
/// 原生侧 [CarMediaCenterBridge] 完成注册与焦点管理后：
/// - 方向盘按键经 `onControl`（native→Dart）下发本类，转成注入的回调；
/// - 原生关键日志经 `onLog`（native→Dart）转发 [AppLogService] 落盘——
///   车机 adb 被封堵的用户只能靠应用内导出日志排查，这是唯一诊断出口；
/// - 播放状态经 [pushState]/[notifyPlayStarted]/[notifyPaused]
///   （Dart→native）上行给媒体中心（HUD 卡片/进度/歌词）。
///
/// 只在 Android 注册（其他平台 no-op；非 ECARX 车机上原生层 bindService
/// 失败即休眠，通道调用静默失败）；[detach] 可安全重复调用。
class CarMediaCenterService {
  CarMediaCenterService({
    @visibleForTesting MethodChannel? channel,
    @visibleForTesting bool? isAndroid,
  })  : _channel = channel ?? const MethodChannel(channelName),
        _isAndroid = isAndroid ?? defaultIsAndroid();

  /// 与 Android 侧 CarMediaCenterBridge.CHANNEL_NAME 保持一致。
  static const String channelName = 'shiyin_music/car_media_center';

  /// 原生下行的控制动作取值。
  static const String actionPlay = 'play';
  static const String actionPause = 'pause';
  static const String actionNext = 'next';
  static const String actionPrevious = 'previous';

  final MethodChannel _channel;
  final bool _isAndroid;
  final Map<String, CarMediaCenterControlCallback> _handlers =
      <String, CarMediaCenterControlCallback>{};
  void Function(String line)? _onLog;
  bool _isAttached = false;

  /// 是否 Android 平台：只有 Android 存在原生媒体中心实现。
  static bool defaultIsAndroid() => !kIsWeb && Platform.isAndroid;

  bool get isAttached => _isAttached;
  bool get isSupported => _isAndroid;

  /// 注册原生回调（控制动作 + 日志转发）。
  ///
  /// 非 Android 平台 no-op；重复调用只更新回调，不重复注册消息处理器。
  void attach({
    required CarMediaCenterControlCallback onPlay,
    required CarMediaCenterControlCallback onPause,
    required CarMediaCenterControlCallback onNext,
    required CarMediaCenterControlCallback onPrevious,
    void Function(String line)? onLog,
  }) {
    if (!_isAndroid) {
      return;
    }
    _handlers
      ..clear()
      ..addAll(<String, CarMediaCenterControlCallback>{
        actionPlay: onPlay,
        actionPause: onPause,
        actionNext: onNext,
        actionPrevious: onPrevious,
      });
    _onLog = onLog;
    if (_isAttached) {
      return;
    }
    _isAttached = true;
    _channel.setMethodCallHandler(_handleMethodCall);
  }

  /// 摘除原生回调；重复调用 no-op。
  void detach() {
    if (!_isAttached) {
      return;
    }
    _isAttached = false;
    _handlers.clear();
    _onLog = null;
    _channel.setMethodCallHandler(null);
  }

  /// 一次上行完整播放状态（曲目/进度/歌词）；原生更新后推给媒体中心。
  Future<void> pushState({
    required String title,
    required String artist,
    String? album,
    String? artwork,
    required int durationMs,
    required int positionMs,
    required bool playing,
    double speed = 1.0,
    String? lyric,
    String? lyricLine,
  }) async {
    if (!_isAndroid) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('pushState', <String, Object?>{
        'title': title,
        'artist': artist,
        'album': album ?? '',
        'artwork': artwork ?? '',
        'durationMs': durationMs,
        'positionMs': positionMs,
        'playing': playing,
        'speed': speed,
        // null-aware 元素：为 null 时整个键省略（原生侧保留上次歌词）。
        'lyric': ?lyric,
        'lyricLine': ?lyricLine,
      });
    } on MissingPluginException {
      // 非 Android/未注册实现：静默。
    } catch (e) {
      debugPrint('[CarMediaCenter] pushState 失败（忽略）: $e');
    }
  }

  /// 真实开播（播放态 false→true）：原生执行 requestPlay 抢媒体焦点，
  /// 方控按键的归属权在这里取得。
  Future<void> notifyPlayStarted() => _invokeVoid('notifyPlayStarted');

  /// 暂停：原生推状态并补一次焦点（暂停后车机会停止派键）。
  Future<void> notifyPaused() => _invokeVoid('notifyPaused');

  /// 拉取原生诊断快照（注册状态/环形日志），预留给日志页排障。
  Future<Map<String, Object?>?> getDiagnostics() async {
    if (!_isAndroid) {
      return null;
    }
    try {
      final result = await _channel
          .invokeMethod<Map<Object?, Object?>>('getDiagnostics');
      return result?.cast<String, Object?>();
    } on MissingPluginException {
      return null;
    } catch (e) {
      debugPrint('[CarMediaCenter] getDiagnostics 失败（忽略）: $e');
      return null;
    }
  }

  Future<void> _invokeVoid(String method) async {
    if (!_isAndroid) {
      return;
    }
    try {
      await _channel.invokeMethod<void>(method);
    } on MissingPluginException {
      // 静默。
    } catch (e) {
      debugPrint('[CarMediaCenter] $method 失败（忽略）: $e');
    }
  }

  /// 原生下行分发：控制动作经回调执行；日志行转发 [AppLogService]。
  Future<dynamic> _handleMethodCall(MethodCall call) async {
    if (!_isAttached) {
      return null;
    }
    switch (call.method) {
      case 'onControl':
        final args = call.arguments;
        final action = args is Map ? args['action'] as String? : null;
        if (action == null) {
          return null;
        }
        final handler = _handlers[action];
        if (handler == null) {
          debugPrint('[CarMediaCenter] 未知控制动作 $action（忽略）');
          return null;
        }
        try {
          await handler();
        } catch (error) {
          // 回调来自播放控制器：媒体键是用户输入，任何失败都不能变成
          // 未捕获异步异常，只记录。
          debugPrint('[CarMediaCenter] 执行 $action 失败（忽略）: $error');
        }
        return null;
      case 'onLog':
        final line = call.arguments as String?;
        if (line != null && line.isNotEmpty) {
          _onLog?.call(line);
        }
        return null;
      default:
        return null;
    }
  }
}
