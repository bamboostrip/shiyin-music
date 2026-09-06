import 'package:flutter/material.dart';

/// 设置页共用小组件：分节标题、卡片容器、瓦片与分隔线。
class SectionHeader extends StatelessWidget {
  const SectionHeader({super.key, required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
          color: Theme.of(context).colorScheme.primary,
          fontWeight: FontWeight.w900,
          fontSize: 15,
          letterSpacing: 0.2,
        ),
      ),
    );
  }
}

class SettingsCard extends StatelessWidget {
  const SettingsCard({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      decoration: BoxDecoration(
        color: isDark ? Colors.white.withValues(alpha: .06) : Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: .10)
              : Colors.white.withValues(alpha: .92),
          width: 1.1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? .18 : .06),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: Column(mainAxisSize: MainAxisSize.min, children: children),
      ),
    );
  }
}

class SettingsTile extends StatelessWidget {
  const SettingsTile({
    super.key,
    required this.icon,
    required this.title,
    this.iconColor,
    this.titleColor,
    this.subtitle,
    this.loading = false,
    this.onTap,
  });

  final IconData icon;
  final Color? iconColor;
  final String title;
  final Color? titleColor;
  final String? subtitle;
  final bool loading;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final effectiveColor = iconColor ?? colorScheme.primary;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: effectiveColor.withValues(alpha: isDark ? .22 : .10),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Center(
                  child: loading
                      ? SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.0,
                            color: effectiveColor,
                          ),
                        )
                      : Icon(icon, size: 20, color: effectiveColor),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        color: titleColor ?? colorScheme.onSurface,
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                      ),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle!,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (onTap != null)
                Icon(
                  Icons.chevron_right_rounded,
                  size: 20,
                  color: colorScheme.onSurfaceVariant.withValues(alpha: .5),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class SettingsSwitchTile extends StatelessWidget {
  const SettingsSwitchTile({
    super.key,
    required this.icon,
    required this.title,
    required this.value,
    required this.onChanged,
    this.iconColor,
    this.subtitle,
  });

  final IconData icon;
  final Color? iconColor;
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final effectiveColor = iconColor ?? colorScheme.primary;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: effectiveColor.withValues(alpha: isDark ? .22 : .10),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Center(child: Icon(icon, size: 20, color: effectiveColor)),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          Switch(
            value: value,
            onChanged: onChanged,
            activeTrackColor: colorScheme.primary,
          ),
        ],
      ),
    );
  }
}

class SettingsDivider extends StatelessWidget {
  const SettingsDivider({super.key});

  @override
  Widget build(BuildContext context) {
    return Divider(
      height: 1,
      indent: 64,
      color: Theme.of(
        context,
      ).colorScheme.outlineVariant.withValues(alpha: .24),
    );
  }
}
