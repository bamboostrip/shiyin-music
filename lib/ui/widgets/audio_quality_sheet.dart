import 'package:flutter/material.dart';

import '../../models/music_models.dart';
import '../form_factor.dart';
import 'desktop_anchored_menu.dart';

Future<AudioQuality?> showAudioQualitySheet({
  required BuildContext context,
  required AudioQuality selected,
  String title = '选择音质',
  String? subtitle,
  Offset? anchor,
  AnchoredPlacement? placement,
}) {
  if (isDesktopFormFactor) {
    if (anchor != null) {
      return Navigator.of(context, rootNavigator: true).push<AudioQuality>(
        DesktopAnchoredPopupRoute<AudioQuality>(
          anchor: anchor,
          placement: placement ??
              (anchor, menuSize, screenSize) {
                if (anchor.dy > screenSize.height / 2) {
                  return placeAnchoredPanelAbove(
                    anchor: Offset(anchor.dx, anchor.dy - 6),
                    panelSize: menuSize,
                    screenSize: screenSize,
                  );
                }
                return placeAnchoredMenu(
                  anchor: Offset(anchor.dx, anchor.dy + 6),
                  menuSize: menuSize,
                  screenSize: screenSize,
                );
              },
          menuBuilder: (menuContext) => DesktopAudioQualityMenu(
            selected: selected,
            title: title,
            onSelect: (quality) => Navigator.of(menuContext).pop(quality),
          ),
          scrimColor: Colors.transparent,
          barrierLabel: '关闭音质菜单',
        ),
      );
    }

    return showDialog<AudioQuality>(
      context: context,
      builder: (dialogContext) {
        final colorScheme = Theme.of(dialogContext).colorScheme;
        return Dialog(
          backgroundColor: colorScheme.surface,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        title,
                        style: Theme.of(dialogContext).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close_rounded),
                        tooltip: '关闭',
                        onPressed: () => Navigator.of(dialogContext).pop(),
                      ),
                    ],
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: Theme.of(dialogContext).textTheme.bodyMedium?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  Material(
                    color: colorScheme.surfaceContainer,
                    borderRadius: BorderRadius.circular(16),
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      children: [
                        for (final quality in AudioQuality.values) ...[
                          ListTile(
                            onTap: () => Navigator.of(dialogContext).pop(quality),
                            leading: Icon(_iconForQuality(quality)),
                            title: Text(quality.label),
                            subtitle: Text(quality.badge),
                            trailing: selected == quality
                                ? Icon(
                                    Icons.check_rounded,
                                    color: colorScheme.primary,
                                  )
                                : null,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16,
                            ),
                          ),
                          if (quality != AudioQuality.values.last)
                            const Divider(height: 1, indent: 58),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  return showModalBottomSheet<AudioQuality>(
    context: context,
    showDragHandle: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    builder: (sheetContext) {
      final colorScheme = Theme.of(sheetContext).colorScheme;
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: Theme.of(
                  sheetContext,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
              ),
              if (subtitle != null) ...[
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: Theme.of(sheetContext).textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
              const SizedBox(height: 12),
              Material(
                color: colorScheme.surfaceContainer,
                borderRadius: BorderRadius.circular(16),
                clipBehavior: Clip.antiAlias,
                child: Column(
                  children: [
                    for (final quality in AudioQuality.values) ...[
                      ListTile(
                        onTap: () => Navigator.of(sheetContext).pop(quality),
                        leading: Icon(_iconForQuality(quality)),
                        title: Text(quality.label),
                        subtitle: Text(quality.badge),
                        trailing: selected == quality
                            ? Icon(
                                Icons.check_rounded,
                                color: colorScheme.primary,
                              )
                            : null,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                        ),
                      ),
                      if (quality != AudioQuality.values.last)
                        const Divider(height: 1, indent: 58),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

IconData _iconForQuality(AudioQuality quality) {
  return switch (quality) {
    AudioQuality.standard => Icons.music_note_rounded,
    AudioQuality.high => Icons.high_quality_rounded,
    AudioQuality.lossless => Icons.graphic_eq_rounded,
  };
}

/// PC 桌面级紧凑音质下拉/气泡菜单（类似 QQ 音乐 / 网易云 PC 客户端）。
class DesktopAudioQualityMenu extends StatelessWidget {
  const DesktopAudioQualityMenu({
    super.key,
    required this.selected,
    required this.onSelect,
    this.title = '切换音质',
  });

  final AudioQuality selected;
  final ValueChanged<AudioQuality> onSelect;
  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    return Material(
      color: Colors.transparent,
      child: Container(
        width: 180,
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF22262E) : Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isDark
                ? Colors.white.withValues(alpha: 0.12)
                : Colors.black.withValues(alpha: 0.08),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? 0.4 : 0.12),
              blurRadius: 16,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
              child: Text(
                title,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: colorScheme.onSurfaceVariant.withValues(alpha: .75),
                ),
              ),
            ),
            Divider(
              height: 1,
              indent: 8,
              endIndent: 8,
              color: colorScheme.outlineVariant.withValues(alpha: .2),
            ),
            const SizedBox(height: 2),
            for (final quality in AudioQuality.values.reversed)
              _DesktopQualityMenuItem(
                quality: quality,
                isSelected: selected == quality,
                onTap: () => onSelect(quality),
              ),
          ],
        ),
      ),
    );
  }
}

class _DesktopQualityMenuItem extends StatefulWidget {
  const _DesktopQualityMenuItem({
    required this.quality,
    required this.isSelected,
    required this.onTap,
  });

  final AudioQuality quality;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  State<_DesktopQualityMenuItem> createState() =>
      _DesktopQualityMenuItemState();
}

class _DesktopQualityMenuItemState extends State<_DesktopQualityMenuItem> {
  bool _isHovering = false;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final hoverBg = isDark
        ? Colors.white.withValues(alpha: 0.08)
        : Colors.black.withValues(alpha: 0.05);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _isHovering = true),
      onExit: (_) => setState(() => _isHovering = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: _isHovering ? hoverBg : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 16,
                child: widget.isSelected
                    ? Icon(
                        Icons.check_rounded,
                        size: 16,
                        color: colorScheme.primary,
                      )
                    : null,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  widget.quality.label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: widget.isSelected
                        ? FontWeight.w700
                        : FontWeight.w500,
                    color: widget.isSelected
                        ? colorScheme.primary
                        : colorScheme.onSurface,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 4,
                  vertical: 1.5,
                ),
                decoration: BoxDecoration(
                  color: widget.isSelected
                      ? colorScheme.primary.withValues(alpha: 0.14)
                      : (isDark
                          ? Colors.white.withValues(alpha: 0.08)
                          : Colors.black.withValues(alpha: 0.06)),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  widget.quality.badge,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: widget.isSelected
                        ? colorScheme.primary
                        : colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

