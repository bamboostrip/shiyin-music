import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import '../../controllers/download_controller.dart';
import '../../controllers/player_controller.dart';
import 'download_location_settings.dart';
import 'download_quality_settings.dart';
import 'settings_widgets.dart';

/// 设置页「存储与下载」分节。
///
/// 把原来的「缓存」与「下载」两节合并：缓存只有 1 项、下载只有 2 项，
/// 分开渲染会让分节长度严重失衡。iOS 不展示下载相关项（系统沙箱限制），
/// 只保留缓存管理。
///
/// [downloads] 未注入时（部分测试 / 未初始化场景）不渲染「下载音质」，
/// 避免出现点了没用的入口；[onOpenManager] 由页面注入缓存管理弹窗逻辑。
class StorageSettingsSection extends StatelessWidget {
  const StorageSettingsSection({
    super.key,
    required this.player,
    required this.onOpenManager,
    this.downloads,
  });

  final DownloadController? downloads;
  final PlayerController player;
  final VoidCallback onOpenManager;

  @override
  Widget build(BuildContext context) {
    final downloads = this.downloads;
    final children = <Widget>[];
    if (!Platform.isIOS) {
      children.add(const DownloadLocationSettings());
      if (downloads != null) {
        children.add(const SettingsDivider());
        children.add(
          DownloadQualitySettings(downloads: downloads, player: player),
        );
      }
      children.add(const SettingsDivider());
    }
    children.add(
      SettingsTile(
        icon: Icons.storage_rounded,
        iconColor: const Color(0xFF009688),
        title: '缓存管理',
        subtitle: '查看和清理缓存',
        onTap: onOpenManager,
      ),
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeader(title: '存储与下载'),
        const SizedBox(height: 8),
        SettingsCard(children: children),
        const SizedBox(height: 20),
      ],
    );
  }
}
