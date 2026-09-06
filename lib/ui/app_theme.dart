import 'package:flutter/material.dart';

import 'design_tokens.dart';
import 'form_factor.dart';

class AppTheme {
  static const blue = Color(0xFF1478FF);
  static const musicRed = Color(0xFFFF2D55);

  /// 桌面形态的页面转场：三桌面平台统一为轻快 fade。
  static const Map<TargetPlatform, PageTransitionsBuilder>
      _desktopPageTransitions = <TargetPlatform, PageTransitionsBuilder>{
    TargetPlatform.windows: _FadePageTransitionsBuilder(),
    TargetPlatform.macOS: _FadePageTransitionsBuilder(),
    TargetPlatform.linux: _FadePageTransitionsBuilder(),
  };

  static ThemeData light({Color? seedColor, bool transparentBackground = false}) {
    return _theme(Brightness.light,
        seedColor: seedColor ?? blue,
        transparentBackground: transparentBackground);
  }

  static ThemeData dark({Color? seedColor, bool transparentBackground = false}) {
    return _theme(Brightness.dark,
        seedColor: seedColor ?? blue,
        transparentBackground: transparentBackground);
  }

  static ThemeData _theme(
    Brightness brightness, {
    Color seedColor = blue,
    bool transparentBackground = false,
  }) {
    final isDark = brightness == Brightness.dark;
    // 桌面形态（OS 判定）才注入桌面主题层；测试经 debugDesktopFormFactorOverride 覆盖。
    final desktop = isDesktopFormFactor;
    final scheme = ColorScheme.fromSeed(seedColor: seedColor, brightness: brightness)
        .copyWith(
          primary: isDark ? _lighten(seedColor, 0.18) : seedColor,
          secondary: musicRed,
          tertiary: const Color(0xFF24C768),
          surface: isDark ? const Color(0xFF0B0C10) : Colors.white,
          surfaceContainerLowest: isDark
              ? const Color(0xFF06070A)
              : Colors.white,
          surfaceContainer: isDark
              ? const Color(0xFF151820)
              : const Color(0xFFF4F7FB),
          surfaceContainerHighest: isDark
              ? const Color(0xFF202430)
              : const Color(0xFFEFF5FF),
          onSurface: isDark ? Colors.white : const Color(0xFF080B12),
          onSurfaceVariant: isDark
              ? const Color(0xFFB0B8C6)
              : const Color(0xFF6F7785),
          outline: isDark ? const Color(0xFF4D5668) : const Color(0xFFD2DAE7),
          outlineVariant: isDark
              ? const Color(0xFF303747)
              : const Color(0xFFE7EDF7),
        );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: transparentBackground
          ? Colors.transparent
          : (isDark ? const Color(0xFF06070A) : Colors.white),
      textTheme: const TextTheme(
        labelSmall: TextStyle(fontSize: 10, height: 1.2),
        bodySmall: TextStyle(fontSize: 12, height: 1.3),
        labelMedium: TextStyle(fontSize: 12, height: 1.3),
        bodyMedium: TextStyle(fontSize: 14, height: 1.4),
        labelLarge: TextStyle(fontSize: 14, height: 1.4),
        bodyLarge: TextStyle(fontSize: 16, height: 1.4),
        titleSmall: TextStyle(fontSize: 16, height: 1.4, fontWeight: FontWeight.w600),
        titleMedium: TextStyle(fontSize: 18, height: 1.4, fontWeight: FontWeight.w600),
        titleLarge: TextStyle(fontSize: 20, height: 1.4, fontWeight: FontWeight.w700),
        headlineSmall: TextStyle(fontSize: 20, height: 1.4, fontWeight: FontWeight.w700),
        headlineMedium: TextStyle(fontSize: 22, height: 1.4, fontWeight: FontWeight.w700),
        displaySmall: TextStyle(fontSize: 22, height: 1.4, fontWeight: FontWeight.w700),
      ),
      fontFamilyFallback: const [
        'SF Pro Display',
        'SF Pro Text',
        'Roboto',
        'Arial',
      ],
      appBarTheme: AppBarTheme(
        centerTitle: false,
        elevation: 0,
        backgroundColor: transparentBackground
            ? Colors.transparent
            : Colors.transparent,
        surfaceTintColor: Colors.transparent,
        foregroundColor: scheme.onSurface,
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          highlightColor: scheme.primary.withValues(alpha: .08),
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        color: scheme.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(AppRadius.lg),
          ),
        ),
        clipBehavior: Clip.antiAlias,
        dragHandleColor: isDark
            ? Colors.white.withValues(alpha: .28)
            : Colors.black.withValues(alpha: .20),
        dragHandleSize: const Size(36, 4),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(48, 44),
          textStyle: const TextStyle(fontWeight: FontWeight.w800),
          shape: const StadiumBorder(),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: isDark ? const Color(0xFF171A22) : Colors.white,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(
            color: scheme.outlineVariant.withValues(alpha: .72),
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: scheme.primary, width: 1.3),
        ),
      ),
      // —— 桌面形态专属主题层 ——
      // 移动端/车机对应项为 null（= Flutter 默认），主题逐项不变。
      scrollbarTheme: desktop ? _desktopScrollbarTheme(scheme) : null,
      tooltipTheme: desktop
          ? const TooltipThemeData(
              waitDuration: AppDesktopTheme.tooltipWaitDuration,
            )
          : null,
      pageTransitionsTheme: desktop
          ? const PageTransitionsTheme(builders: _desktopPageTransitions)
          : null,
    );
  }

  /// 桌面细滚动条：常态半透明细条，hover 加粗加深；轨道全透明，
  /// 颜色统一由 scheme 派生（浅色主题取深字色 / 深色主题取浅字色），两套主题同构。
  static ScrollbarThemeData _desktopScrollbarTheme(ColorScheme scheme) {
    return ScrollbarThemeData(
      thickness: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.hovered)
            ? AppDesktopTheme.scrollbarHoverThickness
            : AppDesktopTheme.scrollbarThickness,
      ),
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.hovered)
            ? scheme.onSurface.withValues(alpha: 0.55)
            : scheme.onSurface.withValues(alpha: 0.30),
      ),
      trackColor: const WidgetStatePropertyAll(Colors.transparent),
      trackBorderColor: const WidgetStatePropertyAll(Colors.transparent),
      radius: AppDesktopTheme.scrollbarRadius,
      crossAxisMargin: AppDesktopTheme.scrollbarCrossAxisMargin,
      mainAxisMargin: AppDesktopTheme.scrollbarMainAxisMargin,
      minThumbLength: AppDesktopTheme.scrollbarMinThumbLength,
    );
  }

  /// 将颜色向白色方向提亮。
  static Color _lighten(Color color, [double amount = 0.2]) {
    return Color.lerp(color, Colors.white, amount) ?? color;
  }
}

/// 桌面轻快页面转场：纯 fade（180ms），替代移动端 Material Zoom 的缩放位移。
/// 忽略 secondaryAnimation：被覆盖页保持静止，新页在其上方淡入（标准桌面 fade）。
class _FadePageTransitionsBuilder extends PageTransitionsBuilder {
  const _FadePageTransitionsBuilder();

  @override
  Duration get transitionDuration => AppDesktopTheme.pageTransitionDuration;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return FadeTransition(
      opacity: animation.drive(CurveTween(curve: Curves.easeOut)),
      child: child,
    );
  }
}
