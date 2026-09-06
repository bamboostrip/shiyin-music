import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';

import '../../controllers/auth_controller.dart';
import '../../controllers/player_controller.dart';
import '../../services/music_api.dart';
import '../form_factor.dart';
import '../pages/audio_interruption_settings_page.dart';
import '../pages/desktop_lyrics_settings_page.dart';
import '../pages/playback_history_page.dart';
import '../pages/playback_stats_page.dart';
import '../widgets/audio_effects_sheet.dart';
import '../widgets/toast.dart';
import 'settings_widgets.dart';

/// 设置页「播放」分节。
///
/// [onSelectDefaultAudioQuality] 由页面注入（默认音质选择弹窗保留在
/// settings_page）。
class PlaybackSettingsSection extends StatelessWidget {
  const PlaybackSettingsSection({
    super.key,
    required this.api,
    required this.auth,
    required this.player,
    required this.onSelectDefaultAudioQuality,
  });

  final MusicApi api;
  final AuthController auth;
  final PlayerController player;
  final VoidCallback onSelectDefaultAudioQuality;

  String _audioInterruptionSummary(PlayerController player) {
    final parts = <String>[];
    if (!player.audioInterruptionEnabled) parts.add('已阻止打断');
    if (player.autoResumeAfterInterruption) parts.add('自动恢复');
    return parts.isEmpty ? '未开启' : parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeader(title: '播放'),
        const SizedBox(height: 8),
        SettingsCard(
          children: [
            SettingsTile(
              icon: Icons.high_quality_rounded,
              iconColor: const Color(0xFF7E57C2),
              title: '默认音质',
              subtitle: player.audioQuality.label,
              onTap: onSelectDefaultAudioQuality,
            ),
            SettingsDivider(),
            SettingsSwitchTile(
              icon: Icons.auto_awesome_rounded,
              iconColor: const Color(0xFF3F51B5),
              title: '智能音质',
              subtitle: '播放失败时自动降级音质重试',
              value: player.smartQualityEnabled,
              onChanged: player.setSmartQualityEnabled,
            ),
            SettingsDivider(),
            SettingsSwitchTile(
              icon: Icons.wifi_rounded,
              iconColor: const Color(0xFF0288D1),
              title: '移动数据下后台缓存',
              subtitle: player.allowCellularPrecache
                  ? '蜂窝网络也会预缓存下一首'
                  : '默认仅 WiFi 下预缓存，省流量',
              value: player.allowCellularPrecache,
              onChanged: player.setAllowCellularPrecache,
            ),
            SettingsDivider(),
            SettingsSwitchTile(
              icon: Icons.power_settings_new_rounded,
              iconColor: const Color(0xFF00897B),
              title: '开机自启播放',
              subtitle: '打开应用时自动播放上次的歌曲',
              value: player.autoPlayOnStartupEnabled,
              onChanged: player.setAutoPlayOnStartupEnabled,
            ),
            SettingsDivider(),
            // 移动端/车机专属：桌面隐藏（含其前导分隔线，避免双线）。
            if (!isDesktopFormFactor) ...[
              SettingsSwitchTile(
                icon: Icons.bluetooth_audio_rounded,
                iconColor: const Color(0xFF00ACC1),
                title: '连接新音频设备自动播放',
                subtitle: '连接蓝牙或耳机时自动恢复播放',
                value: player.autoPlayOnDeviceConnected,
                onChanged: player.setAutoPlayOnDeviceConnected,
              ),
              SettingsDivider(),
            ],
            SettingsSwitchTile(
              icon: Icons.volume_up_rounded,
              iconColor: const Color(0xFF43A047),
              title: '响度均衡',
              // 平台差异如实标注：Windows(WinRT 音量 0..1)无法放大
              // 偏轻歌曲、只能压低偏响歌曲；macOS 无分析通道
              // （Rust 引擎未接入，见 form_factor.dart 清单）。
              subtitle: switch (defaultTargetPlatform) {
                TargetPlatform.windows =>
                  '基于 EBU R128 LUFS 标准化；Windows 仅支持压低偏响歌曲',
                TargetPlatform.macOS => 'macOS 暂不支持响度分析',
                _ => '基于 EBU R128 LUFS 标准化，降低各首歌曲音量差异',
              },
              value: player.loudnessEnabled,
              onChanged: player.setLoudnessEnabled,
            ),
            if (player.isAudioEffectsSupported) ...[
              SettingsDivider(),
              SettingsTile(
                icon: Icons.graphic_eq_rounded,
                iconColor: const Color(0xFF8E24AA),
                title: '音效',
                subtitle: player.audioEffectsLabel,
                onTap: () =>
                    showAudioEffectsSheet(context: context, player: player),
              ),
            ],
            // 尾部分隔线在守卫外：桌面隐藏音效瓦片时，
            // 响度均衡与播放统计之间仍保留分隔线。
            SettingsDivider(),
            SettingsTile(
              icon: Icons.bar_chart_rounded,
              iconColor: const Color(0xFFD81B60),
              title: '播放统计',
              subtitle: '听歌时长、最常听歌手等',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => PlaybackStatsPage(player: player),
                ),
              ),
            ),
            SettingsDivider(),
            SettingsTile(
              icon: Icons.history_rounded,
              iconColor: const Color(0xFF0288D1),
              title: '播放历史',
              subtitle: '最近播放的歌曲',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) =>
                      PlaybackHistoryPage(api: api, auth: auth, player: player),
                ),
              ),
            ),
            SettingsDivider(),
            // 移动端/车机专属：桌面隐藏（含前导分隔线）。
            if (!isDesktopFormFactor) ...[
              SettingsTile(
                icon: Icons.block_rounded,
                iconColor: const Color(0xFFFF7043),
                title: '后台打断机制',
                subtitle: _audioInterruptionSummary(player),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) =>
                        AudioInterruptionSettingsPage(player: player),
                  ),
                ),
              ),
              SettingsDivider(),
              SettingsSwitchTile(
                icon: Icons.timelapse_rounded,
                iconColor: const Color(0xFF7CB342),
                title: '增加听歌时长',
                subtitle: '每播放 30 分钟自动同步一次',
                value: player.addListeningTimeEnabled,
                onChanged: player.setAddListeningTimeEnabled,
              ),
            ],
            if (player.isDesktopLyricsSupported) ...[
              SettingsDivider(),
              SettingsSwitchTile(
                icon: Icons.lyrics_rounded,
                iconColor: const Color(0xFF00B0FF),
                title: '桌面歌词',
                subtitle: '在其他应用上方显示歌词悬浮窗',
                value: player.desktopLyricsEnabled,
                onChanged: (value) async {
                  await player.setDesktopLyricsEnabled(value);
                  if (!player.desktopLyricsEnabled && value) {
                    Toast.error('需要悬浮窗权限才能使用桌面歌词');
                  }
                },
              ),
              if (player.desktopLyricsEnabled) ...[
                SettingsDivider(),
                SettingsTile(
                  icon: Icons.tune_rounded,
                  iconColor: const Color(0xFF651FFF),
                  title: '歌词设置',
                  subtitle: '透明度、颜色、锁定位置等',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => DesktopLyricsSettingsPage(player: player),
                    ),
                  ),
                ),
              ],
              if (player.isBluetoothLyricsSupported) ...[
                SettingsDivider(),
                SettingsSwitchTile(
                  icon: Icons.bluetooth_rounded,
                  iconColor: const Color(0xFF2979FF),
                  title: '车载蓝牙歌词',
                  subtitle: '通过系统广播将歌词同步到车机/第三方歌词 App',
                  value: player.bluetoothLyricsEnabled,
                  onChanged: player.setBluetoothLyricsEnabled,
                ),
              ],
            ],
          ],
        ),
        const SizedBox(height: 20),
      ],
    );
  }
}
