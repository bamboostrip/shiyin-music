import 'package:flutter/material.dart';
import '../design_tokens.dart';

/// Stub for upstream LiquidGlass UI — 在车机分支中以实色卡片替代，避免 BackdropFilter 带来的 GPU 开销。
/// 保留相同 API 以便直接复用上游的布局代码，但内部仅用普通 Card/Container 实现。

class LiquidGlassBackground extends StatelessWidget {
  const LiquidGlassBackground({super.key, required this.child, this.showOrbs = true});
  final Widget child;
  final bool showOrbs;
  @override
  Widget build(BuildContext context) => child;
}

class LiquidGlassCard extends StatelessWidget {
  const LiquidGlassCard({
    super.key,
    required this.child,
    this.borderRadius = AppRadius.xl,
    this.padding,
    this.margin,
    this.width,
    this.height,
    this.onTap,
    this.enableTouchFlex = true,
    this.backgroundColor,
    this.borderColor,
    this.blurSigma = 14.0,
  });
  final Widget child;
  final double borderRadius;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final double? width;
  final double? height;
  final VoidCallback? onTap;
  final bool enableTouchFlex;
  final Color? backgroundColor;
  final Color? borderColor;
  final double blurSigma;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = backgroundColor ??
        (isDark
            ? colorScheme.surfaceContainerHighest
            : Colors.white);
    final border = Border.all(
      color: borderColor ??
          (isDark
              ? colorScheme.outlineVariant.withValues(alpha: .5)
              : colorScheme.outlineVariant.withValues(alpha: .5)),
      width: 1,
    );
    Widget content = Container(
      width: width,
      height: height,
      padding: padding ?? const EdgeInsets.all(AppSpacing.md),
      child: child,
    );
    if (onTap != null) {
      content = Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(borderRadius),
          onTap: onTap,
          child: content,
        ),
      );
    }
    return Container(
      margin: margin,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(borderRadius),
        border: border,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: content,
      ),
    );
  }
}

class LiquidGlassCapsule extends StatelessWidget {
  const LiquidGlassCapsule({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
    this.margin,
    this.onTap,
    this.isActive = false,
    this.activeColor,
  });
  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? margin;
  final VoidCallback? onTap;
  final bool isActive;
  final Color? activeColor;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final active = activeColor ?? colorScheme.primary;
    final bg = isActive
        ? active.withValues(alpha: isDark ? .18 : .12)
        : (isDark
            ? colorScheme.surfaceContainerHighest
            : Colors.white);
    final borderColor = isActive
        ? active.withValues(alpha: .5)
        : colorScheme.outlineVariant.withValues(alpha: .5);
    Widget content = Padding(padding: padding, child: child);
    if (onTap != null) {
      content = Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(100),
          onTap: onTap,
          child: content,
        ),
      );
    }
    return Container(
      margin: margin,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(100),
        border: Border.all(color: borderColor, width: 1),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(100),
        child: content,
      ),
    );
  }
}

class LiquidGlassTile extends StatelessWidget {
  const LiquidGlassTile({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.onTap,
    this.borderRadius = AppRadius.md,
    this.padding = const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
  });
  final Widget title;
  final Widget? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;
  final double borderRadius;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return LiquidGlassCard(
      borderRadius: borderRadius,
      padding: padding,
      onTap: onTap,
      child: Row(
        children: [
          if (leading != null) ...[leading!, const SizedBox(width: 12)],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                title,
                if (subtitle != null) ...[const SizedBox(height: 3), subtitle!],
              ],
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 10), trailing!],
        ],
      ),
    );
  }
}

class LiquidGlassSheetContainer extends StatelessWidget {
  const LiquidGlassSheetContainer({
    super.key,
    required this.child,
    this.borderRadius = AppRadius.lg,
    this.padding,
    this.constraints,
  });
  final Widget child;
  final double borderRadius;
  final EdgeInsetsGeometry? padding;
  final BoxConstraints? constraints;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: constraints,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(borderRadius)),
      ),
      padding: padding,
      child: child,
    );
  }
}
