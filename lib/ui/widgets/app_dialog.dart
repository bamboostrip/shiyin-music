import 'package:flutter/material.dart';

/// 项目统一确认类弹窗语言（参考图版式：18 圆角居中 + 双药丸按钮）。
///
/// - 壳：白底（深色 surfaceContainerLow）、18 圆角、横向 48 边距、
///   最大宽 320、内边距 24/24/22；
/// - 确认按钮：主题色渐变（左端向白提亮 22%，右端 primary 本色）+ 白字；
/// - 取消按钮：中性浅底（#F4F5F7 / 深色 surfaceContainerHighest）+ 深字；
/// - 药丸高 46、整圆角 24、15px w700。
/// 用 Container + InkWell 实现渐变（FilledButton 不支持渐变背景）。
class AppDialogShell extends StatelessWidget {
  const AppDialogShell({
    super.key,
    required this.child,
    this.maxWidth = 320,
  });

  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final dialogBg =
        isDark ? colorScheme.surfaceContainerLow : Colors.white;
    return Dialog(
      backgroundColor: dialogBg,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
      ),
      insetPadding: const EdgeInsets.symmetric(
        horizontal: 48,
        vertical: 24,
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 22),
          child: child,
        ),
      ),
    );
  }
}

/// 弹窗居中标题：17px w800。
class AppDialogTitle extends StatelessWidget {
  const AppDialogTitle(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Text(
      text,
      textAlign: TextAlign.center,
      style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontSize: 17,
            fontWeight: FontWeight.w800,
            color: isDark ? colorScheme.onSurface : const Color(0xFF1A1D24),
            height: 1.3,
          ),
    );
  }
}

/// 弹窗居中正文：14px，次级字色。
class AppDialogMessage extends StatelessWidget {
  const AppDialogMessage(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Text(
      text,
      textAlign: TextAlign.center,
      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            fontSize: 14,
            color: isDark
                ? colorScheme.onSurfaceVariant
                : const Color(0xFF5B606B),
            height: 1.6,
          ),
    );
  }
}

/// 参考图风格的药丸按钮：取消为浅底深字，确认为主题色渐变白字。
class AppPillButton extends StatelessWidget {
  const AppPillButton({
    super.key,
    required this.label,
    required this.foreground,
    required this.onTap,
    this.background,
    this.gradient,
  });

  final String label;
  final Color foreground;
  final Color? background;
  final Gradient? gradient;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(24),
        child: Ink(
          height: 46,
          decoration: BoxDecoration(
            color: gradient == null ? background : null,
            gradient: gradient,
            borderRadius: BorderRadius.circular(24),
          ),
          child: Center(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: foreground,
                fontSize: 15,
                fontWeight: FontWeight.w700,
                height: 1.2,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 弹窗双药丸按钮行：左取消（中性浅底）+ 右确认（主题色渐变）。
class AppDialogPillActions extends StatelessWidget {
  const AppDialogPillActions({
    super.key,
    this.cancelText = '取消',
    required this.confirmText,
    required this.onCancel,
    required this.onConfirm,
    this.confirmEnabled = true,
  });

  final String cancelText;
  final String confirmText;
  final VoidCallback? onCancel;
  final VoidCallback? onConfirm;
  final bool confirmEnabled;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cancelBg = isDark
        ? colorScheme.surfaceContainerHighest
        : const Color(0xFFF4F5F7);
    final cancelFg =
        isDark ? colorScheme.onSurface : const Color(0xFF1A1D24);
    final canConfirm = confirmEnabled && onConfirm != null;
    return Row(
      children: [
        Expanded(
          child: AppPillButton(
            label: cancelText,
            foreground: cancelFg,
            background: cancelBg,
            onTap: onCancel,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: canConfirm
              ? AppPillButton(
                  label: confirmText,
                  foreground: colorScheme.onPrimary,
                  gradient: AppDialogStyle.confirmGradient(colorScheme),
                  onTap: onConfirm,
                )
              // 禁用态：中性浅底 + 次级字色，无点击。
              : AppPillButton(
                  label: confirmText,
                  foreground: colorScheme.onSurfaceVariant
                      .withValues(alpha: 0.55),
                  background: cancelBg,
                  onTap: null,
                ),
        ),
      ],
    );
  }
}

/// 弹窗样式 Token：渐变与遮罩。
abstract final class AppDialogStyle {
  /// 确认按钮主题色渐变：左端向白色提亮 22%，右端为 primary 本色，
  /// 与全局 FilledButton（Stadium + primary）同色系，只是多了渐变质感。
  static LinearGradient confirmGradient(ColorScheme colorScheme) {
    return LinearGradient(
      begin: Alignment.centerLeft,
      end: Alignment.centerRight,
      colors: [
        Color.lerp(colorScheme.primary, Colors.white, 0.22) ??
            colorScheme.primary,
        colorScheme.primary,
      ],
    );
  }

  /// 确认类弹窗统一遮罩：40% 黑。
  static Color barrierColor() => Colors.black.withValues(alpha: 0.4);
}
