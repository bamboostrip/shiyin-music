import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../controllers/auth_controller.dart';
import '../../controllers/download_controller.dart';
import '../../controllers/local_music_controller.dart';
import '../../controllers/player_controller.dart';
import '../../controllers/theme_controller.dart';
import '../../services/cache_service.dart';
import '../../services/music_api.dart';
import '../../services/vip_background_task.dart';
import '../adaptive_layout.dart';
import '../form_factor.dart';
import '../settings/about_settings_section.dart';
import '../settings/account_settings_section.dart';
import '../settings/cache_management_sheet.dart';
import '../settings/cache_settings_section.dart';
import '../settings/desktop_settings_section.dart';
import '../settings/personalization_settings_section.dart';
import '../settings/playback_settings_section.dart';
import '../settings/settings_widgets.dart';
import '../widgets/audio_quality_sheet.dart';
import '../widgets/toast.dart';

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

  Future<void> _selectFontScale(
    BuildContext context,
    ThemeController theme,
  ) async {
    Widget buildOptions(BuildContext ctx) {
      final colorScheme = Theme.of(ctx).colorScheme;
      final isDark = Theme.of(ctx).brightness == Brightness.dark;
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
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final scale in ThemeController.fontScaleOptions) ...[
                InkWell(
                  onTap: () => Navigator.of(ctx).pop(scale),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 14,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          scale == theme.fontScale
                              ? Icons.radio_button_checked_rounded
                              : Icons.radio_button_off_rounded,
                          color: scale == theme.fontScale
                              ? colorScheme.primary
                              : colorScheme.onSurfaceVariant.withValues(
                                  alpha: .6,
                                ),
                          size: 22,
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                fontScaleLabel(scale),
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 15,
                                ),
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
      );
    }

    final double? selected;
    if (isDesktopFormFactor) {
      selected = await showDialog<double>(
        context: context,
        builder: (dialogContext) {
          return Dialog(
            backgroundColor: Theme.of(dialogContext).colorScheme.surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 380),
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
                          '字体大小',
                          style: Theme.of(dialogContext).textTheme.titleLarge
                              ?.copyWith(fontWeight: FontWeight.w900),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close_rounded),
                          tooltip: '关闭',
                          onPressed: () => Navigator.of(dialogContext).pop(),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    buildOptions(dialogContext),
                  ],
                ),
              ),
            ),
          );
        },
      );
    } else {
      selected = await showModalBottomSheet<double>(
        context: context,
        showDragHandle: true,
        backgroundColor: Theme.of(context).colorScheme.surface,
        builder: (sheetContext) {
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '字体大小',
                    style: Theme.of(sheetContext).textTheme.titleLarge
                        ?.copyWith(fontWeight: FontWeight.w900),
                  ),
                  const SizedBox(height: 12),
                  buildOptions(sheetContext),
                ],
              ),
            ),
          );
        },
      );
    }

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
            // 横屏/车机只在平板上出现：手机上无用，桌面上恒横屏且无车机概念。
            final showOrientationTiles =
                !isDesktopFormFactor && AdaptiveLayout.isTablet(context);
            return AdaptiveContentPadding(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(18, 10, 18, 120),
                children: [
                  // Account section
                  AccountSettingsSection(
                    auth: auth,
                    onClaimVip: () => _claimVipNow(context),
                    onLogout: () => _confirmLogout(context),
                  ),
                  // Playback section
                  PlaybackSettingsSection(
                    api: api,
                    auth: auth,
                    player: player,
                    onSelectDefaultAudioQuality: () =>
                        _selectDefaultAudioQuality(context),
                  ),
                  // Desktop section（仅桌面形态：托盘关闭行为 + 窗口重置）
                  if (isDesktopFormFactor) const DesktopSettingsSection(),
                  // Cache section
                  CacheSettingsSection(
                    onOpenManager: () => _showCacheManagement(context),
                  ),
                  // Personalization section
                  PersonalizationSettingsSection(
                    theme: theme,
                    showOrientationTiles: showOrientationTiles,
                    onSelectFontScale: () => _selectFontScale(context, theme),
                  ),
                  // App section
                  AboutSettingsSection(api: api),
                ],
              ),
            );
          },
        ),
      ),
    );
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

  /// 打开缓存管理弹窗（桌面端居中 Dialog，移动端 BottomSheet）。
  Future<void> _showCacheManagement(BuildContext context) async {
    final cache = this.cache;
    final downloads = this.downloads;

    if (isDesktopFormFactor) {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) {
          return Dialog(
            backgroundColor: Theme.of(dialogContext).colorScheme.surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
                child: CacheManagementSheet(
                  cache: cache,
                  downloads: downloads,
                  player: player,
                  isDialog: true,
                ),
              ),
            ),
          );
        },
      );
      return;
    }

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (sheetContext) {
        return CacheManagementSheet(
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
