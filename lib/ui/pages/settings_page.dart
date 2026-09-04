import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../controllers/auth_controller.dart';
import '../../controllers/download_controller.dart';
import '../../controllers/player_controller.dart';
import '../../controllers/theme_controller.dart';
import '../../controllers/local_music_controller.dart';
import '../../services/app_update_service.dart';
import '../../services/cache_service.dart';
import '../../services/music_api.dart';
import '../widgets/audio_effects_sheet.dart';
import '../widgets/audio_quality_sheet.dart';
import '../widgets/toast.dart';
import '../../services/vip_background_task.dart';
import 'about_page.dart';
import 'audio_interruption_settings_page.dart';
import 'desktop_lyrics_settings_page.dart';
import 'personalization_settings_page.dart';
import 'playback_history_page.dart';
import 'playback_stats_page.dart';
import '../adaptive_layout.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({
    super.key,
    required this.api,
    required this.auth,
    required this.player,
    required this.theme,
    this.localMusic,
    this.cache,
    this.downloads,
  });

  final MusicApi api;
  final AuthController auth;
  final PlayerController player;
  final ThemeController theme;
  final LocalMusicController? localMusic;
  final CacheService? cache;
  final DownloadController? downloads;

  String _fontScaleLabel(double scale) {
    if (scale >= 1.2) return '特大';
    if (scale >= 1.1) return '大';
    return '标准';
  }

  Future<void> _selectFontScale(
    BuildContext context,
    ThemeController theme,
  ) async {
    final selected = await showModalBottomSheet<double>(
      context: context,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (sheetContext) {
        final colorScheme = Theme.of(sheetContext).colorScheme;
        final isDark = Theme.of(sheetContext).brightness == Brightness.dark;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '字体大小',
                  style: Theme.of(
                    sheetContext,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 12),
                Container(
                  decoration: BoxDecoration(
                    color: isDark ? Colors.white.withValues(alpha: .06) : Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: isDark
                          ? Colors.white.withValues(alpha: .10)
                          : Colors.white.withValues(alpha: .92),
                      width: 1.1,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: isDark ? .18 : .06),
                        blurRadius: 10,
                        offset: const Offset(0, 3),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final scale in ThemeController.fontScaleOptions) ...[
                          InkWell(
                            onTap: () => Navigator.of(sheetContext).pop(scale),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                              child: Row(
                                children: [
                                  Icon(
                                    scale == theme.fontScale
                                        ? Icons.radio_button_checked_rounded
                                        : Icons.radio_button_off_rounded,
                                    color: scale == theme.fontScale
                                        ? colorScheme.primary
                                        : colorScheme.onSurfaceVariant.withValues(alpha: .6),
                                    size: 22,
                                  ),
                                  const SizedBox(width: 14),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          _fontScaleLabel(scale),
                                          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                                        ),
                                        Text(
                                          scale == 1.0
                                              ? '默认大小'
                                              : scale == 1.1
                                              ? '整体放大 10%'
                                              : '整体放大 20%',
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: colorScheme.onSurfaceVariant,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          if (scale != ThemeController.fontScaleOptions.last)
                            Divider(
                              height: 1,
                              indent: 52,
                              color: colorScheme.outlineVariant.withValues(alpha: .24),
                            ),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (selected != null) {
      await theme.setFontScale(selected);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: colorScheme.brightness == Brightness.dark
            ? Brightness.light
            : Brightness.dark,
        statusBarBrightness: colorScheme.brightness == Brightness.dark
            ? Brightness.dark
            : Brightness.light,
      ),
      child: Scaffold(
        appBar: AppBar(title: const Text('设置')),
        body: AnimatedBuilder(
          animation: Listenable.merge([
            auth,
            player,
            ?localMusic,
            theme,
            auth.vipClaim,
          ]),
          builder: (context, _) {
            return AdaptiveContentPadding(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(18, 10, 18, 120),
                children: [
                  // Account section
                  const _SectionHeader(title: '账号'),
                  const SizedBox(height: 8),
                  _SettingsCard(
                    children: [
                      _SettingsTile(
                        icon: Icons.sync_rounded,
                        iconColor: const Color(0xFF1E88E5),
                        title: '同步个人信息',
                        subtitle: '刷新头像、昵称和歌单数据',
                        loading: auth.isLoading,
                        onTap: auth.isLoading
                            ? null
                            : () => auth.refreshProfile(),
                      ),
                      _SettingsDivider(),
                      _SettingsSwitchTile(
                        icon: Icons.card_giftcard_rounded,
                        iconColor: const Color(0xFFFFA000),
                        title: '自动领取VIP',
                        subtitle: auth.vipClaim.statusText(),
                        value: auth.vipClaim.autoEnabled,
                        onChanged: auth.vipClaim.setAutoEnabled,
                      ),
                      _SettingsDivider(),
                      _SettingsTile(
                        icon: Icons.redeem_rounded,
                        iconColor: const Color(0xFFFF5722),
                        title: '立即领取',
                        subtitle: auth.vipClaim.lastMessage,
                        loading: auth.vipClaim.isClaiming,
                        onTap: auth.vipClaim.isClaiming
                            ? null
                            : () => _claimVipNow(context),
                      ),
                      _SettingsDivider(),
                      _SettingsTile(
                        icon: Icons.logout_rounded,
                        iconColor: colorScheme.error,
                        title: '退出登录',
                        titleColor: colorScheme.error,
                        onTap: auth.isLoading
                            ? null
                            : () => _confirmLogout(context),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  // Playback section
                  const _SectionHeader(title: '播放'),
                  const SizedBox(height: 8),
                  _SettingsCard(
                    children: [
                      _SettingsTile(
                        icon: Icons.high_quality_rounded,
                        iconColor: const Color(0xFF7E57C2),
                        title: '默认音质',
                        subtitle: player.audioQuality.label,
                        onTap: () => _selectDefaultAudioQuality(context),
                      ),
                      _SettingsDivider(),
                      _SettingsSwitchTile(
                        icon: Icons.auto_awesome_rounded,
                        iconColor: const Color(0xFF3F51B5),
                        title: '智能音质',
                        subtitle: '播放失败时自动降级音质重试',
                        value: player.smartQualityEnabled,
                        onChanged: player.setSmartQualityEnabled,
                      ),
                      _SettingsDivider(),
                      _SettingsSwitchTile(
                        icon: Icons.power_settings_new_rounded,
                        iconColor: const Color(0xFF00897B),
                        title: '开机自启播放',
                        subtitle: '打开应用时自动播放上次的歌曲',
                        value: player.autoPlayOnStartupEnabled,
                        onChanged: player.setAutoPlayOnStartupEnabled,
                      ),
                      _SettingsDivider(),
                      _SettingsSwitchTile(
                        icon: Icons.bluetooth_audio_rounded,
                        iconColor: const Color(0xFF00ACC1),
                        title: '连接新音频设备自动播放',
                        subtitle: '连接蓝牙或耳机时自动恢复播放',
                        value: player.autoPlayOnDeviceConnected,
                        onChanged: player.setAutoPlayOnDeviceConnected,
                      ),
                      _SettingsDivider(),
                      _SettingsSwitchTile(
                        icon: Icons.volume_up_rounded,
                        iconColor: const Color(0xFF43A047),
                        title: '响度均衡',
                        subtitle: '基于 EBU R128 LUFS 标准化，降低各首歌曲音量差异',
                        value: player.loudnessEnabled,
                        onChanged: player.setLoudnessEnabled,
                      ),
                      if (player.isAudioEffectsSupported) ...[
                        _SettingsDivider(),
                        _SettingsTile(
                          icon: Icons.graphic_eq_rounded,
                          iconColor: const Color(0xFF8E24AA),
                          title: '音效',
                          subtitle: player.audioEffectsLabel,
                          onTap: () => showAudioEffectsSheet(
                            context: context,
                            player: player,
                          ),
                        ),
                        _SettingsDivider(),
                      ],
                      _SettingsTile(
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
                      _SettingsDivider(),
                      _SettingsTile(
                        icon: Icons.history_rounded,
                        iconColor: const Color(0xFF0288D1),
                        title: '播放历史',
                        subtitle: '最近播放的歌曲',
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => PlaybackHistoryPage(
                              api: api,
                              auth: auth,
                              player: player,
                            ),
                          ),
                        ),
                      ),
                      _SettingsDivider(),
                      _SettingsTile(
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
                      _SettingsDivider(),
                      _SettingsSwitchTile(
                        icon: Icons.timelapse_rounded,
                        iconColor: const Color(0xFF7CB342),
                        title: '增加听歌时长',
                        subtitle: '每播放 30 分钟自动同步一次',
                        value: player.addListeningTimeEnabled,
                        onChanged: player.setAddListeningTimeEnabled,
                      ),
                      if (player.isDesktopLyricsSupported) ...[
                        _SettingsDivider(),
                        _SettingsSwitchTile(
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
                          _SettingsDivider(),
                          _SettingsTile(
                            icon: Icons.tune_rounded,
                            iconColor: const Color(0xFF651FFF),
                            title: '歌词设置',
                            subtitle: '透明度、颜色、锁定位置等',
                            onTap: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) =>
                                    DesktopLyricsSettingsPage(player: player),
                              ),
                            ),
                          ),
                        ],
                        if (player.isBluetoothLyricsSupported) ...[
                          _SettingsDivider(),
                          _SettingsSwitchTile(
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
                  // Cache section
                  const _SectionHeader(title: '缓存'),
                  const SizedBox(height: 8),
                  _SettingsCard(
                    children: [
                      _SettingsTile(
                        icon: Icons.storage_rounded,
                        iconColor: const Color(0xFF009688),
                        title: '缓存管理',
                        subtitle: '查看和清理缓存',
                        onTap: () => _showCacheManagement(context),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  // Personalization section
                  const _SectionHeader(title: '个性化'),
                  const SizedBox(height: 8),
                  _SettingsCard(
                    children: [
                      _SettingsTile(
                        icon: Icons.palette_rounded,
                        iconColor: const Color(0xFFAB47BC),
                        title: '皮肤与背景',
                        subtitle: '配色方案与自定义全局背景图',
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => PersonalizationSettingsPage(
                              themeController: theme,
                            ),
                          ),
                        ),
                      ),
                      _SettingsDivider(),
                      _SettingsTile(
                        icon: Icons.text_fields_rounded,
                        iconColor: const Color(0xFF3F51B5),
                        title: '字体大小',
                        subtitle: _fontScaleLabel(theme.fontScale),
                        onTap: () => _selectFontScale(context, theme),
                      ),
                      _SettingsDivider(),
                      _SettingsSwitchTile(
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
                      _SettingsDivider(),
                      _SettingsSwitchTile(
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
                  ),
                  const SizedBox(height: 20),
                  // App section
                  const _SectionHeader(title: '应用'),
                  const SizedBox(height: 8),
                  _SettingsCard(
                    children: [
                      _SettingsTile(
                        icon: Icons.info_outline_rounded,
                        iconColor: const Color(0xFF607D8B),
                        title: '关于',
                        subtitle: AppUpdateService.isSupportedPlatform
                            ? '版本、更新日志与检查更新'
                            : '版本与更新日志',
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => AboutPage(api: api),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  String _audioInterruptionSummary(PlayerController player) {
    final parts = <String>[];
    if (!player.audioInterruptionEnabled) parts.add('已阻止打断');
    if (player.autoResumeAfterInterruption) parts.add('自动恢复');
    return parts.isEmpty ? '未开启' : parts.join(' · ');
  }

  Future<void> _selectDefaultAudioQuality(BuildContext context) async {
    final quality = await showAudioQualitySheet(
      context: context,
      selected: player.audioQuality,
      title: '默认音质',
      subtitle: '新播放的歌曲会使用这个音质',
    );
    if (quality == null) return;
    await player.setAudioQuality(quality);
  }

  /// 打开缓存管理 BottomSheet。
  Future<void> _showCacheManagement(BuildContext context) async {
    final cache = this.cache;
    final downloads = this.downloads;

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (sheetContext) {
        return _CacheManagementSheet(
          cache: cache,
          downloads: downloads,
          player: player,
        );
      },
    );
  }

  Future<void> _confirmLogout(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('退出登录'),
          content: const Text('确定要退出当前账号吗？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('退出登录'),
            ),
          ],
        );
      },
    );

    if (confirmed != true || !context.mounted) return;
    await auth.logout();
    if (!context.mounted) return;
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  Future<void> _claimVipNow(BuildContext context) async {
    final result = await auth.vipClaim.claimNow(auth.session);
    if (!context.mounted) return;
    // 使用全局 Toast 而非 Scaffold SnackBar，避免随页面返回动画一起位移
    switch (result.status) {
      case VipClaimStatus.success:
        Toast.success(result.message);
        break;
      case VipClaimStatus.alreadyClaimed:
        Toast.info(result.message);
        break;
      case VipClaimStatus.failed:
        Toast.error(result.message);
        break;
      default:
        Toast.show(result.message);
        break;
    }
  }
}

// --- Shared widgets ---

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
          color: Theme.of(context).colorScheme.primary,
          fontWeight: FontWeight.w900,
          fontSize: 15,
          letterSpacing: 0.2,
        ),
      ),
    );
  }
}

class _SettingsCard extends StatelessWidget {
  const _SettingsCard({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      decoration: BoxDecoration(
        color: isDark ? Colors.white.withValues(alpha: .06) : Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: .10)
              : Colors.white.withValues(alpha: .92),
          width: 1.1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? .18 : .06),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: children,
        ),
      ),
    );
  }
}

class _SettingsTile extends StatelessWidget {
  const _SettingsTile({
    required this.icon,
    required this.title,
    this.iconColor,
    this.titleColor,
    this.subtitle,
    this.loading = false,
    this.onTap,
  });

  final IconData icon;
  final Color? iconColor;
  final String title;
  final Color? titleColor;
  final String? subtitle;
  final bool loading;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final effectiveColor = iconColor ?? colorScheme.primary;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: effectiveColor.withValues(alpha: isDark ? .22 : .10),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Center(
                  child: loading
                      ? SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.0,
                            color: effectiveColor,
                          ),
                        )
                      : Icon(
                          icon,
                          size: 20,
                          color: effectiveColor,
                        ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        color: titleColor ?? colorScheme.onSurface,
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                      ),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle!,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (onTap != null)
                Icon(
                  Icons.chevron_right_rounded,
                  size: 20,
                  color: colorScheme.onSurfaceVariant.withValues(alpha: .5),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SettingsSwitchTile extends StatelessWidget {
  const _SettingsSwitchTile({
    required this.icon,
    required this.title,
    required this.value,
    required this.onChanged,
    this.iconColor,
    this.subtitle,
  });

  final IconData icon;
  final Color? iconColor;
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final effectiveColor = iconColor ?? colorScheme.primary;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: effectiveColor.withValues(alpha: isDark ? .22 : .10),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Center(
              child: Icon(
                icon,
                size: 20,
                color: effectiveColor,
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          Switch(
            value: value,
            onChanged: onChanged,
            activeTrackColor: colorScheme.primary,
          ),
        ],
      ),
    );
  }
}

class _SettingsDivider extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Divider(
      height: 1,
      indent: 64,
      color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: .24),
    );
  }
}

/// 缓存管理 BottomSheet。
class _CacheManagementSheet extends StatefulWidget {
  const _CacheManagementSheet({this.cache, this.downloads, this.player});

  final CacheService? cache;
  final DownloadController? downloads;
  final PlayerController? player;

  @override
  State<_CacheManagementSheet> createState() => _CacheManagementSheetState();
}

class _CacheManagementSheetState extends State<_CacheManagementSheet> {
  int? _dataCacheSize;
  int? _downloadSize;
  int? _playCacheSize;
  bool _clearing = false;

  @override
  void initState() {
    super.initState();
    _loadSizes();
  }

  Future<void> _loadSizes() async {
    int? dataCache, download, playCache;
    if (widget.cache != null) {
      try {
        dataCache = await widget.cache!.getCacheSize();
      } catch (_) {}
    }
    if (widget.downloads != null) {
      try {
        download = await widget.downloads!.getDownloadDirSize();
      } catch (_) {}
      try {
        playCache = await widget.downloads!.getPlayCacheDirSize();
      } catch (_) {}
    }
    if (mounted) {
      setState(() {
        _dataCacheSize = dataCache;
        _downloadSize = download;
        _playCacheSize = playCache;
      });
    }
  }

  String _formatSize(int? bytes) {
    if (bytes == null) return '计算中…';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  String _formatLimit(int? bytes) {
    if (bytes == null) return '300 MB';
    if (bytes < 0) return '无限制';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).round()} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).round()} GB';
  }

  Future<void> _selectCacheLimit(BuildContext context) async {
    final downloads = widget.downloads;
    if (downloads == null) return;

    final currentLimit = downloads.playCacheLimit;
    final options = [
      (label: '100 MB', value: 100 * 1024 * 1024),
      (label: '300 MB', value: 300 * 1024 * 1024),
      (label: '500 MB', value: 500 * 1024 * 1024),
      (label: '1 GB', value: 1024 * 1024 * 1024),
      (label: '2 GB', value: 2 * 1024 * 1024 * 1024),
      (label: '5 GB', value: 5 * 1024 * 1024 * 1024),
      (label: '无限制', value: -1),
    ];

    final selected = await showDialog<int>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('设置播放缓存上限'),
          content: SingleChildScrollView(
            child: RadioGroup<int>(
              groupValue: currentLimit,
              onChanged: (val) {
                Navigator.of(dialogContext).pop(val);
              },
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: options.map((opt) {
                  return RadioListTile<int>(
                    title: Text(opt.label),
                    value: opt.value,
                  );
                }).toList(),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('取消'),
            ),
          ],
        );
      },
    );

    if (selected != null && mounted) {
      setState(() => _clearing = true);
      try {
        await downloads.setPlayCacheLimit(selected);
        await _loadSizes();
        Toast.success('已修改缓存上限');
      } catch (_) {
        Toast.error('修改失败');
      }
      if (mounted) {
        setState(() => _clearing = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 0, 18, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '缓存管理',
              style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 16),
            _CacheItem(
              icon: Icons.storage_rounded,
              title: '数据缓存',
              size: _formatSize(_dataCacheSize),
              onClear:
                  widget.cache != null &&
                      _dataCacheSize != null &&
                      _dataCacheSize! > 0
                  ? () async {
                      setState(() => _clearing = true);
                      try {
                        await widget.cache!.clearAllCache();
                        await _loadSizes();
                        if (mounted) {
                          Toast.success('数据缓存已清理');
                        }
                      } catch (_) {
                        if (mounted) {
                          Toast.error('清理失败');
                        }
                      }
                      if (mounted) {
                        setState(() => _clearing = false);
                      }
                    }
                  : null,
            ),
            const SizedBox(height: 10),
            _CacheItem(
              icon: Icons.download_rounded,
              title: '下载文件',
              size: _formatSize(_downloadSize),
              onClear: null, // 下载文件用户主动管理，不提供一键清理
            ),
            const SizedBox(height: 10),
            _CacheItem(
              icon: Icons.cached_rounded,
              title: '播放缓存',
              size: _formatSize(_playCacheSize),
              onClear:
                  widget.downloads != null &&
                      _playCacheSize != null &&
                      _playCacheSize! > 0
                  ? () async {
                      setState(() => _clearing = true);
                      try {
                        await widget.downloads!.clearPlayCache();
                        await _loadSizes();
                        if (mounted) {
                          Toast.success('播放缓存已清理');
                        }
                      } catch (_) {
                        if (mounted) {
                          Toast.error('清理失败');
                        }
                      }
                      if (mounted) {
                        setState(() => _clearing = false);
                      }
                    }
                  : null,
            ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: isDark ? Colors.white.withValues(alpha: .06) : Colors.white,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: isDark ? Colors.white.withValues(alpha: .10) : Colors.white.withValues(alpha: .92),
                  width: 1.1,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: isDark ? .18 : .04),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: colorScheme.primary.withValues(alpha: isDark ? .22 : .10),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      Icons.rule_rounded,
                      size: 20,
                      color: colorScheme.primary,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '播放缓存上限',
                          style: theme.textTheme.bodyLarge?.copyWith(
                            fontWeight: FontWeight.w700,
                            fontSize: 15,
                          ),
                        ),
                        Text(
                          _formatLimit(widget.downloads?.playCacheLimit),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  TextButton(
                    onPressed: () => _selectCacheLimit(context),
                    child: const Text('修改', style: TextStyle(fontWeight: FontWeight.w700)),
                  ),
                ],
              ),
            ),
            if (widget.player != null &&
                widget.player!.isLoudnessAnalysisSupported) ...[
              const SizedBox(height: 10),
              _CacheItem(
                icon: Icons.equalizer_rounded,
                title: '响度分析缓存',
                size: '${widget.player!.loudnessCacheCount} 首',
                onClear: widget.player!.loudnessCacheCount > 0
                    ? () async {
                        setState(() => _clearing = true);
                        try {
                          await widget.player!.clearLoudnessCache();
                          if (mounted) {
                            Toast.success('响度分析缓存已清理');
                          }
                        } catch (_) {
                          if (mounted) {
                            Toast.error('清理失败');
                          }
                        }
                        if (mounted) {
                          setState(() => _clearing = false);
                        }
                      }
                    : null,
              ),
            ],
            const SizedBox(height: 20),
            if (_clearing) const Center(child: CircularProgressIndicator()),
          ],
        ),
      ),
    );
  }
}

/// 缓存管理中的单项条目。
class _CacheItem extends StatelessWidget {
  const _CacheItem({
    required this.icon,
    required this.title,
    required this.size,
    this.onClear,
  });

  final IconData icon;
  final String title;
  final String size;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: isDark ? Colors.white.withValues(alpha: .06) : Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isDark ? Colors.white.withValues(alpha: .10) : Colors.white.withValues(alpha: .92),
          width: 1.1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? .18 : .04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: colorScheme.primary.withValues(alpha: isDark ? .22 : .10),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, size: 20, color: colorScheme.primary),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                  ),
                ),
                Text(
                  size,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          if (onClear != null)
            TextButton(
              onPressed: onClear,
              child: Text(
                '清理',
                style: TextStyle(
                  color: colorScheme.error,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
