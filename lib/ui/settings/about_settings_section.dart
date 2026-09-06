import 'package:flutter/material.dart';

import '../../services/app_update_service.dart';
import '../../services/music_api.dart';
import '../pages/about_page.dart';
import 'settings_widgets.dart';

/// 设置页「应用」分节。
class AboutSettingsSection extends StatelessWidget {
  const AboutSettingsSection({super.key, required this.api});

  final MusicApi api;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeader(title: '应用'),
        const SizedBox(height: 8),
        SettingsCard(
          children: [
            SettingsTile(
              icon: Icons.info_outline_rounded,
              iconColor: const Color(0xFF607D8B),
              title: '关于',
              subtitle: AppUpdateService.isSupportedPlatform
                  ? '版本、更新日志与检查更新'
                  : '版本与更新日志',
              onTap: () => Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => AboutPage(api: api))),
            ),
          ],
        ),
      ],
    );
  }
}
