import 'package:flutter/material.dart';

import 'settings_widgets.dart';

/// 设置页「缓存」分节。
///
/// [onOpenManager] 由页面注入（缓存管理弹窗逻辑保留在 settings_page）。
class CacheSettingsSection extends StatelessWidget {
  const CacheSettingsSection({super.key, required this.onOpenManager});

  final VoidCallback onOpenManager;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeader(title: '缓存'),
        const SizedBox(height: 8),
        SettingsCard(
          children: [
            SettingsTile(
              icon: Icons.storage_rounded,
              iconColor: const Color(0xFF009688),
              title: '缓存管理',
              subtitle: '查看和清理缓存',
              onTap: onOpenManager,
            ),
          ],
        ),
        const SizedBox(height: 20),
      ],
    );
  }
}
