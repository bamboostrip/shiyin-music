import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/ui/app_theme.dart';

/// iOS 状态栏两行修复回归（对应上游 bc90352 / 98ef8e1 / 03737b5）。
///
/// `SystemUiOverlayStyle` 里两个亮度字段语义相反：
/// - `statusBarIconBrightness`（Android）描述**前景**（图标/文字）明暗；
/// - `statusBarBrightness`（iOS）描述**背景**明暗，系统据此自动反色前景。
/// 同向赋值会让 iOS 浅色页面白字白底、深色页面黑字黑底（不可见）。
/// 另：AppBarTheme 背景为 transparent 时必须显式给出 systemOverlayStyle，
/// 否则 iOS 按未知背景推断，标题栏同样会出现不可见状态栏内容。
void main() {
  group('AppBarTheme.systemOverlayStyle', () {
    test('亮色/暗色主题的 Android 前景亮度与 iOS 背景亮度互为镜像', () {
      final light = AppTheme.light().appBarTheme.systemOverlayStyle;
      final dark = AppTheme.dark().appBarTheme.systemOverlayStyle;

      expect(light, isNotNull);
      expect(dark, isNotNull);

      // 浅色：背景浅（iOS light → 深色文字）+ 前景深（Android dark）。
      expect(light!.statusBarBrightness, Brightness.light);
      expect(light.statusBarIconBrightness, Brightness.dark);

      // 深色：背景深（iOS dark → 白色文字）+ 前景浅（Android light）。
      expect(dark!.statusBarBrightness, Brightness.dark);
      expect(dark.statusBarIconBrightness, Brightness.light);

      // iOS 与 Android 两个字段必须始终相反。
      expect(light.statusBarBrightness, isNot(light.statusBarIconBrightness));
      expect(dark.statusBarBrightness, isNot(dark.statusBarIconBrightness));
    });

    test('AppBar 透明背景 + 导航栏颜色跟随主题 surface', () {
      for (final theme in [AppTheme.light(), AppTheme.dark()]) {
        final style = theme.appBarTheme.systemOverlayStyle!;
        expect(style.statusBarColor, Colors.transparent);
        expect(style.systemNavigationBarColor, theme.colorScheme.surface);
        expect(
          style.systemNavigationBarIconBrightness,
          theme.colorScheme.brightness == Brightness.dark
              ? Brightness.light
              : Brightness.dark,
        );
      }
    });
  });
}
