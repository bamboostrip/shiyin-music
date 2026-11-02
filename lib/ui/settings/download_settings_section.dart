import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import 'download_location_settings.dart';
import 'settings_widgets.dart';

/// 设置页「下载」分节：桌面与 Android 共用「下载位置」。
///
/// 从「桌面」分节独立出来，是因为下载位置不再是桌面专属能力：Android
/// 用户同样常需要把歌曲存到系统「音乐」「下载」等文件夹（issue #10）。
///
/// iOS 不展示：应用商店分发之外的 iOS 沙箱不允许写入任意文件夹
/// （需要 security-scoped bookmark 的原生实现），给出入口也改不了，
/// 不如不展示。
class DownloadSettingsSection extends StatelessWidget {
  const DownloadSettingsSection({super.key});

  @override
  Widget build(BuildContext context) {
    if (Platform.isIOS) return const SizedBox.shrink();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeader(title: '下载'),
        const SizedBox(height: 8),
        const SettingsCard(children: [DownloadLocationSettings()]),
        const SizedBox(height: 20),
      ],
    );
  }
}
