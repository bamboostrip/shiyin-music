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
        // 「同时保存 LRC 歌词」原本藏在缓存管理弹层里，PC 用户按更新日志的
        // 路径（设置 → 存储与下载）找不到入口，误以为该功能没上桌面端
        // （issue #29）。这是下载选项而非缓存清理项，放回本分节后所有平台
        // 同一个位置，缓存管理弹层不再重复出现。
        children.add(const SettingsDivider());
        children.add(_SaveLyricsFileTile(downloads: downloads));
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

/// 「同时保存 LRC 歌词」开关。
///
/// 状态来自 [DownloadController]（prefs 持久化，桌面端同样生效）：开启后
/// 每首下载都会在音频旁落一份同名 `.lrc`；标签写不进去时无论开关都会兜底
/// 落一份。用 [AnimatedBuilder] 跟随控制器，避免把整节改成 StatefulWidget。
class _SaveLyricsFileTile extends StatelessWidget {
  const _SaveLyricsFileTile({required this.downloads});

  final DownloadController downloads;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: downloads,
      builder: (context, _) {
        return SettingsSwitchTile(
          icon: Icons.lyrics_outlined,
          iconColor: const Color(0xFF7E57C2),
          title: '同时保存 LRC 歌词',
          subtitle: '下载时额外保留一份同名歌词文件；内嵌失败会自动保存',
          value: downloads.saveLyricsFile,
          onChanged: downloads.setSaveLyricsFile,
        );
      },
    );
  }
}
