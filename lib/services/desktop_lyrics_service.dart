import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../ui/form_factor.dart';
import 'windows_desktop_lyrics_bridge.dart';

typedef DesktopLyricsVisibilityChanged =
    void Function({required bool visible, required bool userClosed});

class DesktopLyricsSettings {
  // 默认 QQ 音乐式透明悬浮：无底色（透明度 0），靠文字阴影保证可读性；
  // 字号 24 在 720x120 悬浮窗内展示效果最佳。用户可在设置页调回底色。
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

  /// Windows 桌面形态的悬浮窗桥接（进程级单例；Android 分支不使用）。
  /// 可见性回调经静态转发交给实例级 [_visibilityChanged]。
  static final WindowsDesktopLyricsBridge? _windowsBridge = isDesktopFormFactor
      ? WindowsDesktopLyricsBridge(
          onVisibilityChanged: _forwardVisibilityChanged,
        )
      : null;

  static void _forwardVisibilityChanged({
    required bool visible,
    required bool userClosed,
  }) {
    _visibilityChanged?.call(visible: visible, userClosed: userClosed);
  }

  DesktopLyricsService() {
    _attachHandler();
  }

  static bool get isSupportedPlatform {
    return !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            // 桌面歌词桥接目前仅在 Windows 验证；macOS/Linux 走同一分支但未经原生验证（子窗口插件注册方式不同）。
            isDesktopFormFactor);
  }

  void setVisibilityChangedHandler(DesktopLyricsVisibilityChanged? handler) {
    _visibilityChanged = handler;
  }

  static void _attachHandler() {
    if (_handlerAttached) return;
    _handlerAttached = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'onVisibilityChanged') {
        return;
      }
      final args = call.arguments;
      if (args is! Map) {
        return;
      }
      _visibilityChanged?.call(
        visible: args['visible'] as bool? ?? false,
        userClosed: args['userClosed'] as bool? ?? false,
      );
    });
  }

  Future<bool> checkPermission() async {
    if (!isSupportedPlatform) return false;
    // Windows：悬浮窗无需特殊权限。
    if (isDesktopFormFactor) return true;
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
    if (isDesktopFormFactor) return;
    try {
      await _channel.invokeMethod<void>('requestPermission');
    } on MissingPluginException {
      // ignore
    }
  }

  Future<bool> show({required String title, required String artist}) async {
    if (!isSupportedPlatform) return false;
    if (isDesktopFormFactor) {
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
    if (isDesktopFormFactor) {
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
    if (isDesktopFormFactor) {
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
    if (isDesktopFormFactor) {
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
    if (isDesktopFormFactor) {
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
    if (isDesktopFormFactor) {
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
    if (isDesktopFormFactor) {
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
    if (isDesktopFormFactor) return _windowsBridge?.isVisible ?? false;
    try {
      final result = await _channel.invokeMethod<bool>('isVisible');
      return result ?? false;
    } on MissingPluginException {
      return false;
    }
  }
}
