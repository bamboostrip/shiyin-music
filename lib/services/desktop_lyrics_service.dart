import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'windows_desktop_lyrics_bridge.dart';

typedef DesktopLyricsVisibilityChanged =
    void Function({required bool visible, required bool userClosed});

typedef DesktopLyricsPlaybackAction = void Function(String action);

/// 子窗工具栏请求切换锁定状态（true=锁定，false=解锁）。
/// 锁定语义 = QQ 音乐式全穿透，锁定/解锁统一由主窗落盘并回推子窗。
typedef DesktopLyricsLockChanged = void Function(bool locked);

class DesktopLyricsSettings {
  // 默认 QQ 音乐式透明悬浮：无底色（透明度 0），靠文字阴影保证可读性；
  // 字号 24 在 780x88 悬浮窗内展示效果最佳。用户可在设置页调回底色。
  const DesktopLyricsSettings({
    this.opacity = 0.0,
    this.locked = false,
    this.passthrough = false,
    this.textColor = 0xFFFFFFFF,
    this.backgroundColor = 0xFF1A1A2E,
    this.fontSize = 24.0,
  });

  final double opacity;
  final bool locked;
  final bool passthrough;
  final int textColor;
  final int backgroundColor;
  final double fontSize;

  DesktopLyricsSettings copyWith({
    double? opacity,
    bool? locked,
    bool? passthrough,
    int? textColor,
    int? backgroundColor,
    double? fontSize,
  }) {
    return DesktopLyricsSettings(
      opacity: opacity ?? this.opacity,
      locked: locked ?? this.locked,
      passthrough: passthrough ?? this.passthrough,
      textColor: textColor ?? this.textColor,
      backgroundColor: backgroundColor ?? this.backgroundColor,
      fontSize: fontSize ?? this.fontSize,
    );
  }

  Map<String, dynamic> toMap() => {
    'opacity': opacity,
    'locked': locked,
    'passthrough': passthrough,
    'textColor': textColor,
    'backgroundColor': backgroundColor,
    'fontSize': fontSize,
  };

  @override
  bool operator ==(Object other) =>
      other is DesktopLyricsSettings &&
      other.opacity == opacity &&
      other.locked == locked &&
      other.passthrough == passthrough &&
      other.textColor == textColor &&
      other.backgroundColor == backgroundColor &&
      other.fontSize == fontSize;

  @override
  int get hashCode => Object.hash(
    opacity,
    locked,
    passthrough,
    textColor,
    backgroundColor,
    fontSize,
  );

  factory DesktopLyricsSettings.fromMap(Map<String, dynamic> map) {
    return DesktopLyricsSettings(
      opacity: (map['opacity'] as num?)?.toDouble() ?? 0.0,
      locked: map['locked'] as bool? ?? false,
      passthrough: map['passthrough'] as bool? ?? false,
      textColor: (map['textColor'] as num?)?.toInt() ?? 0xFFFFFFFF,
      backgroundColor: (map['backgroundColor'] as num?)?.toInt() ?? 0xFF1A1A2E,
      fontSize: (map['fontSize'] as num?)?.toDouble() ?? 24.0,
    );
  }
}

class DesktopLyricsService {
  static const _channel = MethodChannel('kgka_music_hl/desktop_lyrics');
  static bool _handlerAttached = false;
  static DesktopLyricsVisibilityChanged? _visibilityChanged;
  static DesktopLyricsPlaybackAction? _playbackAction;
  static DesktopLyricsLockChanged? _lockChanged;

  /// Windows 桌面形态的悬浮窗桥接（进程级单例；Android 分支不使用）。
  /// 可见性、播控与锁定回调经静态转发交给实例级
  /// [_visibilityChanged] / [_playbackAction] / [_lockChanged]。
  static final WindowsDesktopLyricsBridge? _windowsBridge = _isWindowsDesktop
      ? WindowsDesktopLyricsBridge(
          onVisibilityChanged: _forwardVisibilityChanged,
          onPlaybackAction: _forwardPlaybackAction,
          onLockChanged: _forwardLockChanged,
        )
      : null;

  /// 桌面分支（悬浮窗桥接）仅在 Windows：子窗插件注册方式见
  /// [isSupportedPlatform] 注释。
  static bool get _isWindowsDesktop =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  static void _forwardVisibilityChanged({
    required bool visible,
    required bool userClosed,
  }) {
    _visibilityChanged?.call(visible: visible, userClosed: userClosed);
  }

  static void _forwardPlaybackAction(String action) {
    _playbackAction?.call(action);
  }

  static void _forwardLockChanged(bool locked) {
    _lockChanged?.call(locked);
  }

  DesktopLyricsService() {
    _attachHandler();
  }

  static bool get isSupportedPlatform {
    return !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            // 桌面歌词子窗（desktop_multi_window + window_manager 组合）仅在
            // Windows runner 配置了子窗插件注册（windows/runner/main.cpp 的
            // SetWindowCreatedCallback）。macOS/Linux 的 desktop_multi_window
            // 子引擎只注册插件自身，window_manager 的 frameless/穿透/置顶全部
            // MissingPluginException，悬浮窗会以默认系统边框样式出现且锁定/
            // 穿透失效——在这些平台收窄为不支持，待原生侧补齐注册后再放开。
            defaultTargetPlatform == TargetPlatform.windows);
  }

  /// 应用退出收口：主窗侧直接关闭悬浮子窗（不翻转持久化的开关状态）。
  ///
  /// 必须在 windowManager.destroy() 之前调用——destroy 的原生实现是
  /// PostQuitMessage，进程直接退出，子窗否则被硬杀（拖动位置防抖丢失）。
  static Future<void> shutdown() async {
    await _windowsBridge?.hide();
  }

  void setVisibilityChangedHandler(DesktopLyricsVisibilityChanged? handler) {
    _visibilityChanged = handler;
  }

  void setPlaybackActionHandler(DesktopLyricsPlaybackAction? handler) {
    _playbackAction = handler;
  }

  void setLockChangedHandler(DesktopLyricsLockChanged? handler) {
    _lockChanged = handler;
  }

  static void _attachHandler() {
    if (_handlerAttached) return;
    _handlerAttached = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onVisibilityChanged') {
        final args = call.arguments;
        if (args is! Map) {
          return;
        }
        _visibilityChanged?.call(
          visible: args['visible'] as bool? ?? false,
          userClosed: args['userClosed'] as bool? ?? false,
        );
      } else if (call.method == 'controlPlayback') {
        final action = call.arguments?.toString();
        if (action != null && action.isNotEmpty) {
          _playbackAction?.call(action);
        }
      }
    });
  }

  Future<bool> checkPermission() async {
    if (!isSupportedPlatform) return false;
    // Windows：悬浮窗无需特殊权限。
    if (_isWindowsDesktop) return true;
    try {
      final result = await _channel.invokeMethod<bool>('checkPermission');
      return result ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<void> requestPermission() async {
    if (!isSupportedPlatform) return;
    // Windows：无权限流程，no-op。
    if (_isWindowsDesktop) return;
    try {
      await _channel.invokeMethod<void>('requestPermission');
    } on MissingPluginException {
      // ignore
    }
  }

  Future<bool> show({required String title, required String artist}) async {
    if (!isSupportedPlatform) return false;
    if (_isWindowsDesktop) {
      return await _windowsBridge?.show(title: title, artist: artist) ?? false;
    }
    try {
      await _channel.invokeMethod<void>('show', {
        'title': title,
        'artist': artist,
      });
      return true;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<void> hide() async {
    if (!isSupportedPlatform) return;
    if (_isWindowsDesktop) {
      await _windowsBridge?.hide();
      return;
    }
    try {
      await _channel.invokeMethod<void>('hide');
    } on MissingPluginException {
      // ignore
    }
  }

  Future<void> updateLyrics({
    required String current,
    required String next,
  }) async {
    if (!isSupportedPlatform) return;
    if (_isWindowsDesktop) {
      await _windowsBridge?.updateLyrics(current: current, next: next);
      return;
    }
    try {
      await _channel.invokeMethod<void>('updateLyrics', {
        'current': current,
        'next': next,
      });
    } on MissingPluginException {
      // ignore
    }
  }

  Future<void> updatePlayState({required bool isPlaying}) async {
    if (!isSupportedPlatform) return;
    if (_isWindowsDesktop) {
      await _windowsBridge?.updatePlayState(isPlaying: isPlaying);
      return;
    }
    try {
      await _channel.invokeMethod<void>('updatePlayState', {
        'isPlaying': isPlaying,
      });
    } on MissingPluginException {
      // ignore
    }
  }

  Future<void> updateKaraokeProgress({
    required double progress,
    required Duration? lineDuration,
    required bool isPlaying,
  }) async {
    if (!isSupportedPlatform) return;
    // Windows：v1 整行展示，不做逐字进度。
    if (_isWindowsDesktop) {
      await _windowsBridge?.updateKaraokeProgress(
        progress: progress,
        lineDuration: lineDuration,
        isPlaying: isPlaying,
      );
      return;
    }
    try {
      await _channel.invokeMethod<void>('updateKaraokeProgress', {
        'progress': progress,
        'lineDurationMs': lineDuration?.inMilliseconds ?? 0,
        'isPlaying': isPlaying,
      });
    } on MissingPluginException {
      // ignore
    }
  }

  Future<void> updateSettings(DesktopLyricsSettings settings) async {
    if (!isSupportedPlatform) return;
    if (_isWindowsDesktop) {
      await _windowsBridge?.updateSettings(settings);
      return;
    }
    try {
      await _channel.invokeMethod<void>('updateSettings', settings.toMap());
    } on MissingPluginException {
      // ignore
    }
  }

  Future<void> setAppForeground({required bool isForeground}) async {
    if (!isSupportedPlatform) return;
    if (_isWindowsDesktop) {
      await _windowsBridge?.setAppForeground(isForeground: isForeground);
      return;
    }
    try {
      await _channel.invokeMethod<void>('setAppForeground', {
        'isForeground': isForeground,
      });
    } on MissingPluginException {
      // ignore
    }
  }

  Future<bool> isVisible() async {
    if (!isSupportedPlatform) return false;
    if (_isWindowsDesktop) return _windowsBridge?.isVisible ?? false;
    try {
      final result = await _channel.invokeMethod<bool>('isVisible');
      return result ?? false;
    } on MissingPluginException {
      return false;
    }
  }
}
