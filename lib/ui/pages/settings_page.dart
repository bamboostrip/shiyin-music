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
import '../form_factor.dart';
import '../settings/about_settings_section.dart';
import '../settings/account_settings_section.dart';
import '../settings/cache_management_sheet.dart';
import '../settings/desktop_settings_section.dart';
import '../settings/settings_widgets.dart';
import '../settings/storage_settings_section.dart';
import '../widgets/toast.dart';
import 'personalization_settings_page.dart';
import 'playback_settings_page.dart';

/// 设置主页面：只做「目录」。
///
/// 每个分节长度控制在 1–4 项，最长的「播放」与「外观与个性化」下沉到二级页，
/// 「存储与下载」合并成一个分节；桌面端内容列限制最大宽度，避免卡片横跨
/// 整个窗口。
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

  void _openPlaybackSettings(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlaybackSettingsPage(
          api: api,
          auth: auth,
          player: player,
          // 歌词页切歌键只服务手机/平板形态：PC 与车机（车机模式或车机
          // 设备）均无移动端歌词页底栏，隐藏开关避免「看得到但无效」。
          showLyricPageSkipButtons:
              !isDesktopFormFactor &&
              !theme.carModeEnabled &&
              !theme.isAutomotiveDevice,
        ),
      ),
    );
  }

  void _openPersonalizationSettings(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PersonalizationSettingsPage(themeController: theme),
      ),
    );
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
            return Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(18, 10, 18, 120),
                  children: [
                    // 账号
                    AccountSettingsSection(
                      auth: auth,
                      onClaimVip: () => _claimVipNow(context),
                      onLogout: () => _confirmLogout(context),
                    ),
                    // 播放（二级页）
                    const SectionHeader(title: '播放'),
                    const SizedBox(height: 8),
                    SettingsCard(
                      children: [
                        SettingsTile(
                          icon: Icons.play_circle_outline_rounded,
                          iconColor: const Color(0xFF3F51B5),
                          title: '播放设置',
                          subtitle:
                              '${player.audioQuality.label} · '
                              '智能音质${player.smartQualityEnabled ? '开' : '关'}',
                          onTap: () => _openPlaybackSettings(context),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    // 存储与下载（下载位置 + 下载音质 + 缓存管理）
                    StorageSettingsSection(
                      downloads: downloads,
                      player: player,
                      onOpenManager: () => _showCacheManagement(context),
                    ),
                    // 外观与个性化（二级页）
                    const SectionHeader(title: '外观与个性化'),
                    const SizedBox(height: 8),
                    SettingsCard(
                      children: [
                        SettingsTile(
                          icon: Icons.palette_rounded,
                          iconColor: const Color(0xFFAB47BC),
                          title: '主题与显示',
                          subtitle:
                              '${theme.themeModeLabel} · '
                              '${fontScaleLabel(theme.fontScale)}字号',
                          onTap: () => _openPersonalizationSettings(context),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    // 桌面（仅桌面形态：托盘 + 登录自启 + 窗口重置）
                    if (isDesktopFormFactor) const DesktopSettingsSection(),
                    // 关于与诊断
                    AboutSettingsSection(api: api),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
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
