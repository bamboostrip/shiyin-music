import 'dart:async';
import 'dart:io';

import 'package:audio_service_platform_interface/audio_service_platform_interface.dart';
import 'package:audio_service_win/audio_service_win.dart';
import 'package:audio_service_mpris/audio_service_mpris.dart';
import 'package:flutter/foundation.dart';

/// 桌面系统媒体集成注册（Windows SMTC / Linux MPRIS）。
///
/// audio_service 的平台实现在桌面默认是 NoOpAudioService（见
/// audio_service_platform_interface 的 AudioServicePlatform._instance），
/// 系统媒体键/音量浮层/锁屏控件全部不可用。这里在 [AudioService.init]
/// 之前把对应平台的实现装进 AudioServicePlatform.instance：
///
/// - Windows：audio_service_win（SMTC，原生 C++/WinRT 插件）。
/// - Linux：audio_service_mpris（D-Bus MPRIS，纯 Dart）。
///
/// 必须在 AudioService.init 之前调用：audio_service 顶层字段
/// `_platform` 是懒初始化，首次读取发生在 init 里，晚了就仍指向 NoOp。
///
/// 两个包装类都把 configure 的失败吞掉（无 D-Bus 的 headless Linux、
/// SMTC 初始化异常等），降级为无操作平台，绝不让系统媒体集成的问题
/// 阻断应用启动；降级后 setMediaItem/setState 也一并短路。
void registerDesktopSystemMediaPlatform() {
  if (kIsWeb) return;
  if (Platform.isWindows) {
    AudioServicePlatform.instance = _SafeAudioServiceWin();
  } else if (Platform.isLinux) {
    AudioServicePlatform.instance = _SafeAudioServiceMpris();
  }
}

/// Windows SMTC 包装：configure 失败降级为 no-op。
class _SafeAudioServiceWin extends AudioServiceWin {
  var _broken = false;

  @override
  Future<void> configure(ConfigureRequest request) async {
    try {
      await super.configure(request);
    } catch (error) {
      _broken = true;
      debugPrint('[SystemMedia] Windows SMTC 初始化失败，系统媒体控件降级: $error');
    }
  }

  @override
  Future<void> setMediaItem(SetMediaItemRequest request) async {
    if (_broken) return;
    try {
      await super.setMediaItem(request);
    } catch (error) {
      debugPrint('[SystemMedia] SMTC setMediaItem 失败: $error');
    }
  }

  @override
  Future<void> setState(SetStateRequest request) async {
    if (_broken) return;
    try {
      await super.setState(request);
    } catch (error) {
      debugPrint('[SystemMedia] SMTC setState 失败: $error');
    }
  }
}

/// Linux MPRIS 包装：configure（连 D-Bus、注册 MPRIS 对象）失败降级为
/// no-op。headless/无 D-Bus 会话（部分 WSL、最小化窗口管理器）下必然
/// 失败，不能拖垮启动。
class _SafeAudioServiceMpris extends AudioServiceMpris {
  var _broken = false;

  @override
  Future<void> configure(ConfigureRequest request) async {
    try {
      await super.configure(request);
    } catch (error) {
      _broken = true;
      debugPrint('[SystemMedia] Linux MPRIS 初始化失败（无 D-Bus 会话？），系统媒体控件降级: $error');
    }
  }

  @override
  Future<void> setMediaItem(SetMediaItemRequest request) async {
    if (_broken) return;
    try {
      await super.setMediaItem(request);
    } catch (error) {
      debugPrint('[SystemMedia] MPRIS setMediaItem 失败: $error');
    }
  }

  @override
  Future<void> setState(SetStateRequest request) async {
    if (_broken) return;
    try {
      await super.setState(request);
    } catch (error) {
      debugPrint('[SystemMedia] MPRIS setState 失败: $error');
    }
  }
}
