import 'package:flutter/material.dart';

import '../design_tokens.dart';
import '../form_factor.dart';

/// 外观模式档位：值 + 展示文案 + 图标。
///
/// [label]/[subtitle] 同时供个性化页三卡片选择器与设置页弹窗复用，
/// 保证两处文案完全一致。
class ThemeModeOption {
  const ThemeModeOption({
    required this.mode,
    required this.label,
    required this.subtitle,
    required this.icon,
  });

  /// 该档位对应的 [ThemeMode]。
  final ThemeMode mode;

  /// 档位名称（如「跟随系统」「浅色模式」）。
  final String label;

  /// 档位说明，用于弹窗副标题。
  final String subtitle;

  /// 档位图标。
  final IconData icon;
}

/// 外观模式三档选项，顺序即 UI 展示顺序。
const themeModeOptions = <ThemeModeOption>[
  ThemeModeOption(
    mode: ThemeMode.system,
    label: '跟随系统',
    subtitle: '自动匹配系统深浅色设置',
    icon: Icons.brightness_auto_rounded,
  ),
  ThemeModeOption(
    mode: ThemeMode.light,
    label: '浅色模式',
    subtitle: '强制保持浅色外观',
    icon: Icons.light_mode_rounded,
  ),
  ThemeModeOption(
    mode: ThemeMode.dark,
    label: '深色模式',
    subtitle: '强制保持夜间深色外观',
    icon: Icons.dark_mode_rounded,
  ),
];

/// 外观模式三卡片选择器（跟随系统 / 浅色 / 深色）。
///
/// 选中态用 [ColorScheme.primaryContainer] 底 + primary 描边，未选中态用
/// 低透明度 surfaceContainerHighest 底，深浅两套主题下均有足够对比度。
class ThemeModeSelector extends StatelessWidget {
  const ThemeModeSelector({
    super.key,
    required this.currentMode,
    required this.onChanged,
  });

  /// 当前生效的外观模式。
  final ThemeMode currentMode;

  /// 点击某一档位时回调；由调用方负责持久化。
  final ValueChanged<ThemeMode> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Row(
        children: [
          for (final option in themeModeOptions) ...[
            if (option != themeModeOptions.first) const SizedBox(width: 12),
            Expanded(
              child: _ThemeModeCard(
                option: option,
                selected: option.mode == currentMode,
                onTap: () => onChanged(option.mode),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 单个外观模式卡片。
class _ThemeModeCard extends StatelessWidget {
  const _ThemeModeCard({
    required this.option,
    required this.selected,
    required this.onTap,
  });

  final ThemeModeOption option;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final foreground = selected
        ? colorScheme.primary
        : colorScheme.onSurfaceVariant;

    return Material(
      color: selected
          ? colorScheme.primaryContainer
          : colorScheme.surfaceContainerHighest.withValues(alpha: .5),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        side: BorderSide(
          color: selected ? colorScheme.primary : Colors.transparent,
          width: 1.5,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        mouseCursor: isDesktopFormFactor ? SystemMouseCursors.click : null,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(option.icon, size: 26, color: foreground),
              const SizedBox(height: 8),
              Text(
                option.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: foreground,
                  fontWeight: selected ? FontWeight.bold : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
