import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import '../../controllers/download_controller.dart';
import '../../controllers/player_controller.dart';
import 'download_location_settings.dart';
import 'download_quality_settings.dart';
import 'settings_widgets.dart';

/// 设置页「下载」分节：桌面与 Android 共用「下载位置」「下载音质」。
///
/// 从「桌面」分节独立出来，是因为下载位置不再是桌面专属能力：Android
/// 用户同样常需要把歌曲存到系统「音乐」「下载」等文件夹（issue #10）。
///
/// 「下载音质」（issue #8）需要 [DownloadController] 读写覆盖值；未注入
/// controller 的调用点（部分测试、未初始化场景）只展示下载位置，不显示
/// 一个点了没用的入口。
///
/// iOS 不展示：应用商店分发之外的 iOS 沙箱不允许写入任意文件夹
/// （需要 security-scoped bookmark 的原生实现），给出入口也改不了，
/// 不如不展示。
class DownloadSettingsSection extends StatelessWidget {
  const DownloadSettingsSection({
    super.key,
    this.downloads,
    required this.player,
  });

  final DownloadController? downloads;

  /// 仅用于「下载音质」跟随态展示当前播放档位。
  final PlayerController player;

  @override
  Widget build(BuildContext context) {
    if (Platform.isIOS) return const SizedBox.shrink();
    // 提升为局部变量以获得非空提升（公共 final 字段不参与 field promotion）。
    final downloads = this.downloads;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeader(title: '下载'),
        const SizedBox(height: 8),
        SettingsCard(
          children: [
            const DownloadLocationSettings(),
            if (downloads != null) ...[
              const SettingsDivider(),
              DownloadQualitySettings(downloads: downloads, player: player),
            ],
          ],
        ),
        const SizedBox(height: 20),
      ],
    );
  }
}
