import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../controllers/auth_controller.dart';
import '../../controllers/download_controller.dart';
import '../../controllers/local_music_controller.dart';
import '../../controllers/player_controller.dart';
import '../../controllers/theme_controller.dart';
import '../../services/cache_service.dart';
import '../../services/music_api.dart';
import '../pages/downloaded_songs_page.dart';
import '../pages/home_page.dart';
import '../pages/library_page.dart';
import '../pages/player_page.dart';
import '../pages/search_page.dart';
import '../pages/settings_page.dart';
import '../keyboard_focus_guard.dart';
import '../widgets/lazy_indexed_stack.dart';
import 'desktop_player_bar.dart';
import 'desktop_sidebar.dart';

/// 桌面骨架的内容分区。home 分区对应 HomePage 的三个子 tab
/// （推荐/排行榜/电台），由侧栏直接切换。
enum _DesktopSection { home, library, downloads, settings }

/// 桌面 Shell：左侧导航栏 + 内容区 + 底部播放栏（QQ 音乐 PC 式三段布局）。
///
/// 复用 HomePage 既有的 sectionIndex/onTabSwitch 外部 tab 控制通道，
/// 页面实例保存在 LazyIndexedStack 中，切分区不丢状态。
/// 车机模式在本骨架中不存在（isDesktopFormFactor 已在最外层分流）。
class DesktopShell extends StatefulWidget {
  const DesktopShell({
    super.key,
    required this.api,
    required this.auth,
    required this.player,
    required this.cache,
    required this.downloads,
    required this.theme,
    required this.localMusic,
  });

  final MusicApi api;
  final AuthController auth;
  final PlayerController player;
  final CacheService cache;
  final DownloadController downloads;
  final ThemeController theme;
  final LocalMusicController localMusic;

  @override
  State<DesktopShell> createState() => _DesktopShellState();
}

class _DesktopShellState extends State<DesktopShell> {
  _DesktopSection _section = _DesktopSection.home;

  /// HomePage 子 tab（0=推荐, 1=排行榜, 2=电台），HomePage.sectionIndex 语义。
  var _homeTab = 0;

  /// 内容区内嵌导航：歌单/搜索/歌手等详情只覆盖中间内容区，
  /// 侧栏与底部播放栏常驻（PC 软件逻辑）。内层页面的
  /// `Navigator.of(context).push` 会自动命中本 Navigator，无需改调用点。
  final _contentNavKey = GlobalKey<NavigatorState>();

  /// Tab 切换修订号：内嵌 Navigator 会缓存 `/` 路由，父级 setState
  /// 不会重建路由内容，故用 notifier 显式驱动 [_DesktopContent] 重建。
  final _tabsRevision = ValueNotifier<int>(0);

  @override
  void dispose() {
    _tabsRevision.dispose();
    super.dispose();
  }

  /// 回到内容根页（切换侧栏分区时关闭已打开的歌单/搜索等详情）。
  void _popToContentRoot() {
    final inner = _contentNavKey.currentState;
    if (inner != null && inner.canPop()) {
      inner.popUntil((route) => route.isFirst);
    }
  }

  /// HomePage.onTabSwitch 的 shell 级下标语义（0=我的, 1..3=三个子 tab）。
  /// 越界值静默钳制，防止侧栏高亮失步（HomePage 当前只发 0..3，防御性收敛）。
  void _handleHomeTabSwitch(int shellIndex) {
    setState(() {
      final clamped = shellIndex.clamp(0, 3);
      if (clamped <= 0) {
        _section = _DesktopSection.library;
      } else {
        _section = _DesktopSection.home;
        _homeTab = clamped - 1;
      }
    });
    _tabsRevision.value++;
  }

  void _selectSection(int sidebarIndex) {
    _popToContentRoot();
    setState(() {
      if (sidebarIndex <= 2) {
        _section = _DesktopSection.home;
        _homeTab = sidebarIndex;
      } else {
        _section = _DesktopSection.values[sidebarIndex - 2];
      }
    });
    _tabsRevision.value++;
  }

  /// 内容区内推页（保留侧栏+底栏）。内层 Navigator 尚未就绪时
  /// 退回根 Navigator，避免快捷键时序导致打不开。
  void _pushContent(BuildContext context, Widget page) {
    final inner = _contentNavKey.currentState;
    if (inner != null) {
      inner.push(MaterialPageRoute(builder: (_) => page));
    } else {
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
    }
  }

  void _openSearch(BuildContext context) {
    _pushContent(
      context,
      SearchPage(api: widget.api, auth: widget.auth, player: widget.player),
    );
  }

  void _openPlayerPage(BuildContext context) {
    if (widget.player.currentSong == null) return;
    _pushContent(
      context,
      PlayerPage(player: widget.player, auth: widget.auth),
    );
  }

  int get _sidebarIndex {
    return switch (_section) {
      _DesktopSection.home => _homeTab,
      _DesktopSection.library => 3,
      _DesktopSection.downloads => 4,
      _DesktopSection.settings => 5,
    };
  }

  int get _contentIndex {
    return switch (_section) {
      _DesktopSection.home => 0,
      _DesktopSection.library => 1,
      _DesktopSection.downloads => 2,
      _DesktopSection.settings => 3,
    };
  }

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.keyF, control: true):
            _OpenSearchIntent(),
        SingleActivator(LogicalKeyboardKey.digit1, control: true):
            _SelectHomeSectionIntent(0),
        SingleActivator(LogicalKeyboardKey.digit2, control: true):
            _SelectHomeSectionIntent(1),
        SingleActivator(LogicalKeyboardKey.digit3, control: true):
            _SelectHomeSectionIntent(2),
        SingleActivator(LogicalKeyboardKey.enter):
            _OpenPlayerIntent(),
        SingleActivator(LogicalKeyboardKey.numpadEnter):
            _OpenPlayerIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _OpenSearchIntent: CallbackAction<_OpenSearchIntent>(
            onInvoke: (_) {
              // 焦点在输入框/按钮内时让位：避免遮蔽控件自身的 Enter/空格激活。
              if (isFocusInsideInteractiveControl()) return null;
              _openSearch(context);
              return null;
            },
          ),
          _SelectHomeSectionIntent:
              CallbackAction<_SelectHomeSectionIntent>(
            onInvoke: (intent) {
              if (isFocusInsideInteractiveControl()) return null;
              _selectSection(intent.index);
              return null;
            },
          ),
          _OpenPlayerIntent: CallbackAction<_OpenPlayerIntent>(
            onInvoke: (_) {
              if (isFocusInsideInteractiveControl()) return null;
              _openPlayerPage(context);
              return null;
            },
          ),
        },
        child: Scaffold(
      body: Row(
        children: [
          DesktopSidebar(
            items: const [
              DesktopNavItem(
                icon: Icons.explore_outlined,
                activeIcon: Icons.explore_rounded,
                label: '推荐',
              ),
              DesktopNavItem(
                icon: Icons.leaderboard_outlined,
                activeIcon: Icons.leaderboard_rounded,
                label: '排行榜',
              ),
              DesktopNavItem(
                icon: Icons.radio_rounded,
                activeIcon: Icons.radio_rounded,
                label: '电台',
              ),
              DesktopNavItem(
                icon: Icons.library_music_outlined,
                activeIcon: Icons.library_music_rounded,
                label: '我的音乐',
              ),
              DesktopNavItem(
                icon: Icons.download_outlined,
                activeIcon: Icons.download_rounded,
                label: '已下载',
              ),
              DesktopNavItem(
                icon: Icons.settings_outlined,
                activeIcon: Icons.settings_rounded,
                label: '设置',
                showDividerAbove: true,
              ),
            ],
            selectedIndex: _sidebarIndex,
            onSelect: _selectSection,
            onSearch: () => _openSearch(context),
          ),
          const VerticalDivider(width: 1, thickness: 1),
          Expanded(
            child: Column(
              children: [
                Expanded(
                  // 内容区内嵌导航：`/` 为分区内容（侧栏切换），push 的
                  // 歌单/搜索/歌手详情只覆盖本区域，侧栏与底栏常驻。
                  child: Navigator(
                    key: _contentNavKey,
                    initialRoute: '/',
                    onGenerateRoute: (settings) {
                      if (settings.name == '/') {
                        return MaterialPageRoute(
                          settings: settings,
                          builder: (_) => _DesktopContent(
                            revision: _tabsRevision,
                            sectionProvider: () => _section,
                            homeTabProvider: () => _homeTab,
                            contentIndexProvider: () => _contentIndex,
                            api: widget.api,
                            auth: widget.auth,
                            player: widget.player,
                            cache: widget.cache,
                            downloads: widget.downloads,
                            theme: widget.theme,
                            localMusic: widget.localMusic,
                            onHomeTabSwitch: _handleHomeTabSwitch,
                          ),
                        );
                      }
                      return null;
                    },
                  ),
                ),
                DesktopPlayerBar(player: widget.player, auth: widget.auth),
              ],
            ),
          ),
        ],
      ),
        ),
      ),
    );
  }
}

/// 桌面骨架专属快捷键意图。
class _OpenSearchIntent extends Intent {
  const _OpenSearchIntent();
}

class _SelectHomeSectionIntent extends Intent {
  const _SelectHomeSectionIntent(this.index);
  final int index;
}

class _OpenPlayerIntent extends Intent {
  const _OpenPlayerIntent();
}

/// 桌面内容根页：分区 Tab 容器，活在内嵌 Navigator 的 `/` 路由下。
///
/// 经 [_DesktopShellState._tabsRevision] 驱动重建（内嵌 Navigator 会缓存
/// 路由，父级 setState 到不了这里）。各分区的页面实例由
/// [LazyIndexedStack] 保活，切分区不丢滚动与加载状态。
class _DesktopContent extends StatelessWidget {
  const _DesktopContent({
    required this.revision,
    required this.sectionProvider,
    required this.homeTabProvider,
    required this.contentIndexProvider,
    required this.api,
    required this.auth,
    required this.player,
    required this.cache,
    required this.downloads,
    required this.theme,
    required this.localMusic,
    required this.onHomeTabSwitch,
  });

  final ValueNotifier<int> revision;
  final _DesktopSection Function() sectionProvider;
  final int Function() homeTabProvider;
  final int Function() contentIndexProvider;
  final MusicApi api;
  final AuthController auth;
  final PlayerController player;
  final CacheService cache;
  final DownloadController downloads;
  final ThemeController theme;
  final LocalMusicController localMusic;
  final ValueChanged<int> onHomeTabSwitch;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: revision,
      builder: (_, _, _) {
        return LazyIndexedStack(
          index: contentIndexProvider(),
          children: [
            HomePage(
              api: api,
              auth: auth,
              player: player,
              cache: cache,
              theme: theme,
              downloads: downloads,
              localMusic: localMusic,
              sectionIndex: homeTabProvider(),
              onTabSwitch: onHomeTabSwitch,
            ),
            LibraryPage(
              api: api,
              auth: auth,
              player: player,
              downloads: downloads,
              theme: theme,
              localMusic: localMusic,
            ),
            DownloadedSongsPage(api: api, auth: auth, player: player, downloads: downloads),
            SettingsPage(
              api: api,
              auth: auth,
              player: player,
              theme: theme,
              localMusic: localMusic,
              cache: cache,
              downloads: downloads,
            ),
          ],
        );
      },
    );
  }
}
