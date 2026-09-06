import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:audio_service/audio_service.dart';
import 'package:flutter/services.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:local_notifier/local_notifier.dart';

import 'config/app_config.dart';
import 'controllers/auth_controller.dart';
import 'controllers/download_controller.dart';
import 'controllers/player_controller.dart';
import 'controllers/local_music_controller.dart';
import 'controllers/theme_controller.dart';
import 'core/api_client_interface.dart';
import 'core/rust_api_client.dart';
import 'services/cache_service.dart';
import 'services/desktop_lyrics_service.dart';
import 'services/desktop_system_integration.dart';
import 'services/desktop_system_media.dart';
import 'services/device_info_service.dart';
import 'services/download_service.dart';
import 'services/music_audio_handler.dart';
import 'services/music_api.dart';
import 'services/network_monitor.dart';
import 'ui/adaptive_layout.dart';
import 'ui/desktop/desktop_tray.dart';
import 'ui/desktop/desktop_window.dart';
import 'ui/desktop/lyrics_overlay_window.dart';
import 'ui/app_theme.dart';
import 'ui/form_factor.dart';
import 'ui/pages/app_shell.dart';
import 'ui/pages/login_page.dart';
import 'ui/widgets/toast.dart';

Future<void> main(List<String> args) async {
  // desktop_multi_window 子窗口（桌面歌词悬浮窗）入口分流：
  // 子窗口引擎会以 args=['multi_window', id, arguments] 重新执行 main()，
  // 必须最先识别并 return，严禁执行音频服务/主窗窗口管理等重量级初始化。
  if (isLyricsOverlayWindowArgs(args)) {
    await runLyricsOverlayWindow(args);
    return;
  }
  WidgetsFlutterBinding.ensureInitialized();
  // 图片缓存策略（车机 2-4GB RAM，内存有限但不宜过小）：
  // - maximumSizeBytes = 64MB：封面经 Artwork 解码后最大 600×600×4B ≈ 1.4MB/张，
  //   64MB 约可容纳 44 张满尺寸封面或数百张列表小图，来回切页基本全部命中缓存，
  //   不再反复下载；对 2-4GB 设备约占内存 2~3%，低于 Flutter 手机默认 100MB。
  // - maximumSize = 200：张数兜底，防止大量极小缩略图塞满条目数。
  // 超限后由 ImageCache 按 LRU 自动淘汰，避免手动全清导致切页重下。
  final cache = PaintingBinding.instance.imageCache;
  cache.maximumSize = 200;
  cache.maximumSizeBytes = 64 << 20;
  final client = await RustApiClient.getInstance();
  final api = MusicApi(client);

  // 桌面形态（Windows 等）：初始化窗口尺寸/最小尺寸/几何记忆。
  // 必须在 runApp 之前完成，避免首帧以错误尺寸渲染。
  await DesktopWindow.ensureInitialized();
  final themeController = ThemeController();
  await themeController.detectAutomotive(const DeviceInfoService());
  await themeController.load();

  final channelConfig = resolvePlaybackNotificationChannel(
    isCarMode: themeController.carModeEnabled,
    isAutomotiveDevice: themeController.isAutomotiveDevice,
  );

  // Linux 桌面：just_audio 无官方 Linux 平台实现，注册社区 media_kit(libmpv)
  // 后端（见 pubspec.yaml 依赖注释）。必须在创建首个 AudioPlayer
  // （AudioService.init → MusicAudioHandler 字段初始化）之前调用；
  // 仅在 Linux 分支注册，避免覆盖 Windows 的 just_audio_windows 后端。
  // kIsWeb 前置：web 上访问 Platform.isLinux 会直接 throw（当前 web 构建
  // 因 dart:io 无法编译，此为防御性收敛，保持与 form_factor 判定同构）。
  if (!kIsWeb && Platform.isLinux) {
    JustAudioMediaKit.ensureInitialized();
  }

  // 桌面系统媒体集成：Windows SMTC（音量浮层/媒体键/锁屏控件）与
  // Linux MPRIS（GNOME/KDE 媒体控件/媒体键）。audio_service 在桌面默认
  // 走 NoOp 平台实现，这里替换为对应平台实现；必须在 AudioService.init
  // 之前调用（audio_service 的 _platform 懒初始化发生在 init 内）。
  // 平台实现初始化失败（无 D-Bus 等）内部已降级，不会阻断启动。
  registerDesktopSystemMediaPlatform();

  final audioHandler = await AudioService.init(
    builder: MusicAudioHandler.new,
    config: AudioServiceConfig(
      androidNotificationChannelId: channelConfig.channelId,
      androidNotificationChannelName: channelConfig.channelName,
      androidStopForegroundOnPause: false,
    ),
  );

  runApp(
    ShiyinApp(
      client: client,
      api: api,
      audioHandler: audioHandler,
      themeController: themeController,
    ),
  );
}

class ShiyinApp extends StatefulWidget {
  const ShiyinApp({
    super.key,
    required this.client,
    required this.api,
    required this.audioHandler,
    required this.themeController,
  });

  final ApiClientInterface client;
  final MusicApi api;
  final MusicAudioHandler audioHandler;
  final ThemeController themeController;

  @override
  State<ShiyinApp> createState() => _ShiyinAppState();
}

class _ShiyinAppState extends State<ShiyinApp> with WidgetsBindingObserver {
  late final ApiClientInterface _client;
  late final MusicApi _api;
  late final CacheService _cacheService;
  late final DownloadService _downloadService;
  late final DownloadController _downloads;
  late final AuthController _auth;
  late final PlayerController _player;
  late final ThemeController _theme;
  late final LocalMusicController _localMusic;

  /// 主窗标题随播放（仅桌面形态创建并绑定）。
  DesktopWindowTitleBinder? _windowTitleBinder;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _client = widget.client;
    _api = widget.api;
    _cacheService = CacheService();
    _downloadService = DownloadService();
    _downloads = DownloadController(_downloadService, _api);
    _auth = AuthController(_api, _cacheService);
    _localMusic = LocalMusicController();
    _player = PlayerController(_api, widget.audioHandler)
      ..downloadController = _downloads
      ..cacheService = _cacheService
      ..localMusic = _localMusic
      ..vipClaim = _auth.vipClaim;
    unawaited(NetworkMonitor.instance.start());
    _theme = widget.themeController;
    _auth.restore();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _downloads.initialize();
    });
    // Windows 桌面：托盘常驻（左键切换窗口、右键菜单、退出）。
    if (isDesktopFormFactor) {
      // 退出收口（托盘"退出"/关闭按钮 destroy 分支都会经过）：
      // destroy 的原生实现是 PostQuitMessage，进程直接退出、Dart 侧没有
      // 优雅关闭机会——桌面歌词子窗与托盘图标必须在 destroy 之前清理，
      // 否则子窗被硬杀（拖动位置防抖丢失）、托盘残留幽灵图标。
      DesktopWindow.onBeforeQuit = () async {
        await DesktopLyricsService.shutdown();
        await DesktopTray.dispose();
      };
      unawaited(DesktopTray.init(player: _player));
      // 桌面系统集成：下载完成通知 + 主窗标题随播放。
      // local_notifier 初始化失败时降级为无通知，不影响其余功能。
      unawaited(_initDesktopNotifications());
      _windowTitleBinder = DesktopWindowTitleBinder(
        titleOf: () => _player.currentSong?.title,
        artistOf: () => _player.currentSong?.artist,
      )..attach(_player);
    }
  }

  /// 桌面下载完成通知：初始化 local_notifier（通知点击把主窗带到前台）
  /// 并注入下载控制器；移动端/车机不进入本路径。
  Future<void> _initDesktopNotifications() async {
    try {
      await localNotifier.setup(appName: AppConfig.appName);
      _downloads.desktopNotifier = const LocalNotifierDownloadNotifier();
    } catch (error) {
      debugPrint('ShiyinApp: local_notifier 初始化失败，下载通知降级: $error');
    }
  }

  @override
  void dispose() {
    // 先摘除托盘，避免销毁中的控制器再被托盘菜单回调触发。
    unawaited(DesktopTray.dispose());
    // 解除标题监听，避免悬空回调触发 windowManager.setTitle。
    _windowTitleBinder?.detach();
    WidgetsBinding.instance.removeObserver(this);
    unawaited(NetworkMonitor.instance.stop());
    _auth.dispose();
    _player.dispose();
    _downloads.dispose();
    _localMusic.dispose();
    _downloadService.dispose();
    _client.close();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    switch (state) {
      case AppLifecycleState.resumed:
        if (_player.desktopLyricsEnabled) _player.setAppForeground(true);
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
        if (_player.desktopLyricsEnabled) _player.setAppForeground(false);
      case AppLifecycleState.paused:
        if (_player.desktopLyricsEnabled) _player.setAppForeground(false);
        // 图片缓存内存保护（后台驻留时不长期占用大量解码位图）：
        // - 缓存量较小时保留，切后台再回前台不重新下载，避免反复加载；
        // - 缓存量较大（>24MB）才整体释放，兼顾车机有限内存与加载体感。
        // 不再调用 clearLiveImages()：它会把当前正在显示的图流也强制释放，
        // 回到前台时整屏重新解码/下载，是"切页后图片反复重下"的根源之一。
        if (PaintingBinding.instance.imageCache.currentSizeBytes > 24 << 20) {
          PaintingBinding.instance.imageCache.clear();
        }
      case AppLifecycleState.detached:
        if (_player.desktopLyricsEnabled) _player.setAppForeground(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    _theme.applyOrientations(AdaptiveLayout.isTablet(context));
    return AnimatedBuilder(
      animation: _theme,
      builder: (context, _) {
        return MaterialApp(
          title: AppConfig.appName,
          debugShowCheckedModeBanner: false,
          navigatorKey: Toast.navigatorKey,
          themeMode: ThemeMode.system,
          theme: AppTheme.light(
            seedColor: _theme.seedColor,
            transparentBackground: _theme.backgroundEnabled,
          ),
          darkTheme: AppTheme.dark(
            seedColor: _theme.seedColor,
            transparentBackground: _theme.backgroundEnabled,
          ),
          builder: (context, child) {
            // 全局字体大小（保留系统无障碍缩放）。
            final baseScale = MediaQuery.textScalerOf(context).scale(1.0);
            final textScaler = TextScaler.linear(baseScale * _theme.fontScale);
            Widget result = MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: textScaler),
              child: _AppBackground(
                themeController: _theme,
                child: _SystemUiOverlay(
                  child: child ?? const SizedBox.shrink(),
                ),
              ),
            );
            // Windows 桌面 AXTree 竞态导致原生崩溃（accessibility_bridge.cc），
            // 整 app 排除语义树彻底规避。Android/iOS 不受影响。
            if (Platform.isWindows) {
              result = ExcludeSemantics(child: result);
            }
            return result;
          },
          home: AnimatedBuilder(
            animation: _auth,
            builder: (context, _) {
              if (!_auth.isRestoring && !_auth.isLoggedIn) {
                return LoginPage(auth: _auth, api: _api);
              }

              return AppShell(
                api: _api,
                auth: _auth,
                player: _player,
                cache: _cacheService,
                downloads: _downloads,
                theme: _theme,
                localMusic: _localMusic,
              );
            },
          ),
        );
      },
    );
  }
}

/// 全局背景图层。
///
/// 当用户启用了自定义背景图时，在所有页面内容下方显示背景图，
/// 并叠加半透明遮罩（由 [ThemeController.backgroundOpacity] 控制）。
class _AppBackground extends StatefulWidget {
  const _AppBackground({required this.themeController, required this.child});

  final ThemeController themeController;
  final Widget child;

  @override
  State<_AppBackground> createState() => _AppBackgroundState();
}

class _AppBackgroundState extends State<_AppBackground> {
  ImageProvider? _imageProvider;
  String? _cachedPath;

  @override
  void initState() {
    super.initState();
    widget.themeController.addListener(_onThemeChanged);
    _updateProvider();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _precacheBackground();
    });
  }

  @override
  void didUpdateWidget(covariant _AppBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.themeController != widget.themeController) {
      oldWidget.themeController.removeListener(_onThemeChanged);
      widget.themeController.addListener(_onThemeChanged);
      _updateProvider();
      _precacheBackground();
    }
  }

  @override
  void dispose() {
    widget.themeController.removeListener(_onThemeChanged);
    super.dispose();
  }

  void _onThemeChanged() {
    _updateProvider();
    _precacheBackground();
    setState(() {});
  }

  void _updateProvider() {
    final path = widget.themeController.backgroundImagePath;
    if (path != null && path != _cachedPath) {
      _cachedPath = path;
      _imageProvider = ResizeImage(
        FileImage(File(path)),
        width: 800,
        height: 800,
      );
    }
  }

  void _precacheBackground() {
    if (_imageProvider != null) {
      precacheImage(_imageProvider!, context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.themeController.backgroundEnabled;
    final path = widget.themeController.backgroundImagePath;

    if (!enabled || path == null || _imageProvider == null) {
      return widget.child;
    }

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final overlayColor = isDark ? const Color(0xFF06070A) : Colors.white;
    final opacity = widget.themeController.backgroundOpacity;

    return Stack(
      children: [
        // 背景图层（复用同一个 FileImage provider，避免重复解码）
        Positioned.fill(
          child: Image(
            image: _imageProvider!,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => const SizedBox.shrink(),
          ),
        ),
        // 半透明遮罩（opacity 越大遮罩越透明，背景图越明显）
        Positioned.fill(
          child: ColoredBox(
            color: overlayColor.withValues(alpha: 1.0 - opacity),
          ),
        ),
        // 页面内容
        widget.child,
      ],
    );
  }
}

class _SystemUiOverlay extends StatelessWidget {
  const _SystemUiOverlay({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colorScheme = Theme.of(context).colorScheme;
    final overlayStyle = SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
      statusBarBrightness: isDark ? Brightness.light : Brightness.dark,
      systemNavigationBarColor: colorScheme.surface,
      systemNavigationBarIconBrightness: isDark
          ? Brightness.light
          : Brightness.dark,
      systemStatusBarContrastEnforced: false,
      systemNavigationBarContrastEnforced: false,
    );

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: overlayStyle,
      child: child,
    );
  }
}
