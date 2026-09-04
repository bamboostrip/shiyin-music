import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/ui/app_theme.dart';
import 'package:shiyin_music/ui/design_tokens.dart';
import 'package:shiyin_music/ui/form_factor.dart';

void main() {
  tearDown(() => debugDesktopFormFactorOverride = null);

  group('桌面主题层（isDesktopFormFactor = true）', () {
    test('注入细滚动条主题（厚度/圆角/边距/最小长度均来自 token）', () {
      debugDesktopFormFactorOverride = true;
      for (final theme in [AppTheme.light(), AppTheme.dark()]) {
        final scrollbar = theme.scrollbarTheme;
        expect(
          scrollbar.thickness!.resolve(const <WidgetState>{}),
          AppDesktopTheme.scrollbarThickness,
        );
        expect(
          scrollbar.thickness!.resolve(const {WidgetState.hovered}),
          AppDesktopTheme.scrollbarHoverThickness,
        );
        expect(scrollbar.radius, AppDesktopTheme.scrollbarRadius);
        expect(scrollbar.crossAxisMargin, AppDesktopTheme.scrollbarCrossAxisMargin);
        expect(scrollbar.mainAxisMargin, AppDesktopTheme.scrollbarMainAxisMargin);
        expect(scrollbar.minThumbLength, AppDesktopTheme.scrollbarMinThumbLength);
        // 轨道不绘制（纯 overlay 细条）。
        expect(scrollbar.trackColor!.resolve(const <WidgetState>{}), Colors.transparent);
      }
    });

    test('滚动条颜色由 scheme 派生：常态半透明，hover 加深，深浅主题取值不同', () {
      debugDesktopFormFactorOverride = true;
      final light = AppTheme.light();
      final dark = AppTheme.dark();
      expect(
        light.scrollbarTheme.thumbColor!.resolve(const <WidgetState>{}),
        light.colorScheme.onSurface.withValues(alpha: 0.30),
      );
      expect(
        light.scrollbarTheme.thumbColor!.resolve(const {WidgetState.hovered}),
        light.colorScheme.onSurface.withValues(alpha: 0.55),
      );
      expect(
        dark.scrollbarTheme.thumbColor!.resolve(const <WidgetState>{}),
        dark.colorScheme.onSurface.withValues(alpha: 0.30),
      );
      // 深浅主题的 thumb 颜色必然不同（分别取各自的 onSurface）。
      expect(
        light.scrollbarTheme.thumbColor!.resolve(const <WidgetState>{}),
        isNot(dark.scrollbarTheme.thumbColor!.resolve(const <WidgetState>{})),
      );
    });

    test('tooltipTheme 统一 waitDuration（light + dark）', () {
      debugDesktopFormFactorOverride = true;
      for (final theme in [AppTheme.light(), AppTheme.dark()]) {
        expect(theme.tooltipTheme.waitDuration, AppDesktopTheme.tooltipWaitDuration);
      }
    });

    test('pageTransitionsTheme 仅配三桌面平台 fade，且转场时长为轻快 token', () {
      debugDesktopFormFactorOverride = true;
      final builders = AppTheme.light().pageTransitionsTheme.builders;
      expect(builders.keys, unorderedEquals(<TargetPlatform>{
        TargetPlatform.windows,
        TargetPlatform.macOS,
        TargetPlatform.linux,
      }));
      expect(
        builders[TargetPlatform.windows]!.transitionDuration,
        AppDesktopTheme.pageTransitionDuration,
      );
      // 与移动端默认（Zoom 300ms）确有差异。
      expect(
        builders[TargetPlatform.windows]!.transitionDuration,
        isNot(ZoomPageTransitionsBuilder().transitionDuration),
      );
    });

    testWidgets('桌面 MaterialPageRoute 实际采用 fade 转场时长（180ms）', (tester) async {
      debugDesktopFormFactorOverride = true;
      // 与 Windows 桌面运行时一致：ThemeData.platform = windows 时
      // PageTransitionsTheme 才选中桌面 fade builder。
      final theme = AppTheme.light().copyWith(platform: TargetPlatform.windows);
      MaterialPageRoute<void>? pushed;
      await tester.pumpWidget(MaterialApp(
        theme: theme,
        home: Scaffold(
          body: TextButton(
            onPressed: () {
              pushed = MaterialPageRoute<void>(
                builder: (_) => const Scaffold(body: SizedBox.shrink()),
              );
              Navigator.of(tester.element(find.text('push'))).push(pushed!);
            },
            child: const Text('push'),
          ),
        ),
      ));
      await tester.tap(find.text('push'));
      await tester.pumpAndSettle();
      expect(pushed!.transitionDuration, AppDesktopTheme.pageTransitionDuration);
    });
  });

  group('移动端/车机主题（isDesktopFormFactor = false）', () {
    test('scrollbar/tooltip 主题均为空数据（保持 Flutter 默认，无 waitDuration）', () {
      debugDesktopFormFactorOverride = false;
      for (final theme in [AppTheme.light(), AppTheme.dark()]) {
        expect(theme.scrollbarTheme, const ScrollbarThemeData());
        expect(theme.tooltipTheme, const TooltipThemeData());
        expect(theme.tooltipTheme.waitDuration, isNull);
      }
    });

    test('pageTransitionsTheme 保持 Flutter 默认 builders', () {
      debugDesktopFormFactorOverride = false;
      final expected = PageTransitionsTheme().builders;
      for (final theme in [AppTheme.light(), AppTheme.dark()]) {
        expect(theme.pageTransitionsTheme.builders, same(expected));
      }
    });
  });
}
