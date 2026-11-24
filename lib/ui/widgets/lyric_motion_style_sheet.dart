import 'package:flutter/material.dart';

import '../../models/lyric_motion_style.dart';
import '../form_factor.dart';

/// 选择播放页歌词动效样式（issue #26）。
///
/// 移动端底部弹层、PC 居中对话框；返回 null 表示用户取消。
Future<LyricMotionStyle?> showLyricMotionStyleSheet({
  required BuildContext context,
  required LyricMotionStyle selected,
}) {
  if (isDesktopFormFactor) {
    return showDialog<LyricMotionStyle>(
      context: context,
      builder: (dialogContext) {
        final colorScheme = Theme.of(dialogContext).colorScheme;
        return Dialog(
          backgroundColor: colorScheme.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
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
                        '歌词动效',
                        style: Theme.of(dialogContext).textTheme.titleLarge
                            ?.copyWith(fontWeight: FontWeight.w900),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close_rounded),
                        tooltip: '关闭',
                        onPressed: () => Navigator.of(dialogContext).pop(),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '播放页歌词的切换动效；桌面歌词悬浮窗与车机分栏歌词暂不跟随',
                    style: Theme.of(dialogContext).textTheme.bodyMedium
                        ?.copyWith(color: colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 16),
                  _LyricMotionStyleOptions(
                    selected: selected,
                    onSelect: (style) => Navigator.of(dialogContext).pop(style),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  return showModalBottomSheet<LyricMotionStyle>(
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
                '歌词动效',
                style: Theme.of(
                  sheetContext,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 4),
              Text(
                '播放页歌词的切换动效；桌面歌词悬浮窗与车机分栏歌词暂不跟随',
                style: Theme.of(sheetContext).textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              _LyricMotionStyleOptions(
                selected: selected,
                onSelect: (style) => Navigator.of(sheetContext).pop(style),
              ),
            ],
          ),
        ),
      );
    },
  );
}

class _LyricMotionStyleOptions extends StatelessWidget {
  const _LyricMotionStyleOptions({
    required this.selected,
    required this.onSelect,
  });

  final LyricMotionStyle selected;
  final ValueChanged<LyricMotionStyle> onSelect;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: colorScheme.surfaceContainer,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (final style in LyricMotionStyle.values) ...[
            ListTile(
              onTap: () => onSelect(style),
              leading: Icon(_iconForStyle(style)),
              title: Text(
                style.label,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              subtitle: Text(style.description),
              trailing: selected == style
                  ? Icon(Icons.check_rounded, color: colorScheme.primary)
                  : null,
              contentPadding: const EdgeInsets.symmetric(horizontal: 16),
            ),
            if (style != LyricMotionStyle.values.last)
              const Divider(height: 1, indent: 58),
          ],
        ],
      ),
    );
  }
}

IconData _iconForStyle(LyricMotionStyle style) {
  return switch (style) {
    LyricMotionStyle.standard => Icons.text_fields_rounded,
    LyricMotionStyle.lively => Icons.auto_awesome_rounded,
  };
}
