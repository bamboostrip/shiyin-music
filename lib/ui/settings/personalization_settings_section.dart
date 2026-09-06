import 'package:flutter/material.dart';

import '../../controllers/theme_controller.dart';
import '../adaptive_layout.dart';
import '../pages/personalization_settings_page.dart';
import '../widgets/toast.dart';
import 'settings_widgets.dart';

/// 字号档位对应的中文文案。
String fontScaleLabel(double scale) {
  if (scale >= 1.2) return '特大';
  if (scale >= 1.1) return '大';
  return '标准';
}

/// 设置页「个性化」分节。
///
/// [showOrientationTiles] 由页面按形态计算后传入（横屏/车机只在平板上
/// 出现）；[onSelectFontScale] 由页面注入（字体大小弹窗保留在
/// settings_page）。
class PersonalizationSettingsSection extends StatelessWidget {
  const PersonalizationSettingsSection({
    super.key,
    required this.theme,
    required this.showOrientationTiles,
    required this.onSelectFontScale,
  });

  final ThemeController theme;
  final bool showOrientationTiles;
  final VoidCallback onSelectFontScale;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeader(title: '个性化'),
        const SizedBox(height: 8),
        SettingsCard(
          children: [
            SettingsTile(
              icon: Icons.palette_rounded,
              iconColor: const Color(0xFFAB47BC),
              title: '皮肤与背景',
              subtitle: '配色方案与自定义全局背景图',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) =>
                      PersonalizationSettingsPage(themeController: theme),
                ),
              ),
            ),
            SettingsDivider(),
            SettingsTile(
              icon: Icons.text_fields_rounded,
              iconColor: const Color(0xFF3F51B5),
              title: '字体大小',
              subtitle: fontScaleLabel(theme.fontScale),
              onTap: onSelectFontScale,
            ),
            SettingsDivider(),
            if (showOrientationTiles) ...[
              SettingsSwitchTile(
                icon: Icons.screen_rotation_rounded,
                iconColor: const Color(0xFF00897B),
                title: '横屏模式',
                subtitle: '允许手机横屏时自动旋转（平板默认开启）',
                value: theme.landscapeEnabled,
                onChanged: (value) {
                  theme.setLandscapeEnabled(
                    value,
                    AdaptiveLayout.isTablet(context),
                  );
                },
              ),
              SettingsDivider(),
              SettingsSwitchTile(
                icon: Icons.directions_car_rounded,
                iconColor: const Color(0xFFFF6F00),
                title: '车机模式',
                subtitle: '横屏时使用左侧播放面板布局并放大文字',
                value: theme.carModeEnabled,
                onChanged: (value) async {
                  await theme.setCarModeEnabled(value);
                  // 通知渠道在启动时按车机模式定向，切换后需完全重启
                  // 进程才生效；原生车机设备始终走静默渠道，无需提示
                  if (!theme.isAutomotiveDevice) {
                    Toast.show(
                      '车机模式已切换，建议重启应用以同步通知栏显示方式',
                      duration: const Duration(seconds: 4),
                    );
                  }
                },
              ),
            ],
          ],
        ),
        const SizedBox(height: 20),
      ],
    );
  }
}
