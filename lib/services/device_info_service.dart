import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 设备类型检测服务。
///
/// 通过 MethodChannel 调用原生层判断是否为 Android Automotive 车机。
/// 非 Android 平台恒返回 false。
///
/// **通道就绪时序**：`AudioServiceActivity.provideFlutterEngine()` 会在 Activity
/// attach 之前就 `executeDartEntrypoint()`（见 audio_service 0.18.19
/// `AudioServicePlugin.getFlutterEngine`），而本项目所有 `shiyin_music/*` 自定义
/// 通道是在 `MainActivity.configureFlutterEngine` 里注册的——于是 Dart 入口
/// 跑到这里时通道可能还不存在，调用直接抛 `MissingPluginException`。
///
/// 因此本服务返回 `bool?`：**null 表示「这次没能问出来」**，调用方必须把它和
/// 「明确不是车机」区分开，稍后重试（issue #24：车机首次安装被判成手机，车机
/// 模式默认关闭且不会自动纠正）。
class DeviceInfoService {
  const DeviceInfoService();

  static const MethodChannel _channel = MethodChannel('shiyin_music/device');

  static bool get isSupportedPlatform {
    return !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  }

  /// 是否为 Android Automotive 车机。
  ///
  /// - `true`：原生明确判定为车机；
  /// - `false`：原生明确判定不是（非 Android 平台也返回 false）；
  /// - `null`：通道尚未注册 / 原生抛错 / 超时——**必须稍后重试**，不能当作
  ///   "不是车机"落盘，否则车机模式会被永久判成关闭。
  Future<bool?> isAutomotive({
    Duration timeout = const Duration(milliseconds: 800),
  }) async {
    if (!isSupportedPlatform) return false;
    try {
      return await _channel.invokeMethod<bool>('isAutomotive').timeout(timeout);
    } on TimeoutException {
      return null;
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    } catch (_) {
      return null;
    }
  }
}
