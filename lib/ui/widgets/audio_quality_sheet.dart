import 'package:flutter/material.dart';

import '../../models/music_models.dart';
import '../form_factor.dart';

Future<AudioQuality?> showAudioQualitySheet({
  required BuildContext context,
  required AudioQuality selected,
  String title = '选择音质',
  String? subtitle,
}) {
  if (isDesktopFormFactor) {
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
