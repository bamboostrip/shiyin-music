import 'package:flutter/material.dart';

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
import '../pages/search_page.dart';
import '../pages/settings_page.dart';
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

  /// HomePage.onTabSwitch 的 shell 级下标语义（0=我的, 1..3=三个子 tab）。
  void _handleHomeTabSwitch(int shellIndex) {
    setState(() {
      if (shellIndex <= 0) {
        _section = _DesktopSection.library;
      } else {
        _section = _DesktopSection.home;
        _homeTab = shellIndex - 1;
      }
    });
  }

  void _selectSection(int sidebarIndex) {
    setState(() {
      if (sidebarIndex <= 2) {
        _section = _DesktopSection.home;
        _homeTab = sidebarIndex;
      } else {
        _section = _DesktopSection.values[sidebarIndex - 2];
      }
    });
  }

  void _openSearch(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SearchPage(
          api: widget.api,
          auth: widget.auth,
          player: widget.player,
        ),
      ),
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
    final pages = [
      HomePage(
        api: widget.api,
        auth: widget.auth,
        player: widget.player,
        cache: widget.cache,
        theme: widget.theme,
        downloads: widget.downloads,
        localMusic: widget.localMusic,
        sectionIndex: _homeTab,
        onTabSwitch: _handleHomeTabSwitch,
      ),
      LibraryPage(
        api: widget.api,
        auth: widget.auth,
        player: widget.player,
        downloads: widget.downloads,
        theme: widget.theme,
        localMusic: widget.localMusic,
      ),
      DownloadedSongsPage(
        api: widget.api,
        auth: widget.auth,
        player: widget.player,
        downloads: widget.downloads,
      ),
      SettingsPage(
        api: widget.api,
        auth: widget.auth,
        player: widget.player,
        theme: widget.theme,
        localMusic: widget.localMusic,
        cache: widget.cache,
        downloads: widget.downloads,
      ),
    ];

    return Scaffold(
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
                  child: LazyIndexedStack(
                    index: _contentIndex,
                    children: pages,
                  ),
                ),
                DesktopPlayerBar(player: widget.player, auth: widget.auth),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
