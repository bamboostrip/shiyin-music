import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../../controllers/auth_controller.dart';
import '../../controllers/download_controller.dart';
import '../../controllers/local_music_controller.dart';
import '../../controllers/player_controller.dart';
import '../../controllers/theme_controller.dart';
import '../../services/cache_service.dart';
import '../../services/music_api.dart';
import '../pages/comment_page.dart';
import '../pages/artist_detail_page.dart';
import '../pages/desktop_lyrics_settings_page.dart';
import '../pages/downloaded_songs_page.dart';
import '../pages/home_page.dart';
import '../pages/identify_page.dart';
import '../pages/library_page.dart';
import '../pages/search_page.dart';
import '../pages/settings_page.dart';
import '../keyboard_focus_guard.dart';
import '../player/player_route.dart';
import '../widgets/lazy_indexed_stack.dart';
import 'desktop_player_bar.dart';
import 'desktop_search_suggest_panel.dart';
import 'desktop_sidebar.dart';
import 'desktop_title_bar.dart';

/// 侧栏双击检测用的时钟，可注入（测试替换假时钟）；默认取真实时间。
/// 与 app_shell 的 appShellNow 同一模式，各自独立互不依赖。
DateTime Function() desktopShellNow = DateTime.now;

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
    this.windowRestorer,
  });

  final MusicApi api;
  final AuthController auth;
  final PlayerController player;
  final CacheService cache;
  final DownloadController downloads;
  final ThemeController theme;
  final LocalMusicController localMusic;
  final Future<void> Function()? windowRestorer;

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

  /// 首页三分区（推荐/排行榜/电台）的回顶刷新入口：侧栏双击当前分区时
  /// 经此调用 [HomePageState.scrollToTopAndRefresh]（含顶部均衡器动画）。
  final _homePageKey = GlobalKey<HomePageState>();

  /// 侧栏双击检测窗口。Windows 系统双击时限默认 500ms（GetDoubleClickTime），
  /// 鼠标双击节奏普遍慢于触屏点按（移动端「首页」用 350ms），故取 500ms。
  static const _sidebarDoubleClickInterval = Duration(milliseconds: 500);
  int? _lastSidebarTapIndex;
  DateTime? _lastSidebarTapTime;

  /// 顶栏搜索（QQ 音乐 PC 式）：可输入胶囊 + 聚焦时热门/历史浮层，
  /// 提交后结果页嵌入内容区，侧栏保持可见。
  final _searchController = TextEditingController();
  final _searchFocusNode = FocusNode();
  var _searchPanelOpen = false;

  /// 内容区导航栈上当前搜索结果页的路由（用于连搜时 replace 而非叠层）。
  ///
  /// 必须跟踪路由对象而非布尔标记：pushReplacement 下旧路由的 popped
  /// 会在新路由动画完成后才触发（SDK 的 complete→didComplete 链），布尔
  /// 版本会被旧路由的 whenComplete 误清，下一次连搜从 replace 退化成
  /// 叠层；且"栈顶是否搜索页"要靠路由身份判断，canPop() 判断会把搜索
  /// 页上方push的歌手/歌单详情页错误地替换掉。
  Route<void>? _searchRoute;

  /// 内容区导航栈上是否已有歌词设置页（避免重复打开叠层）。
  var _lyricsSettingsPageOpen = false;

  @override
  void initState() {
    super.initState();
    try {
      widget.player.openLyricsSettingsRequest
          .addListener(_onOpenLyricsSettingsRequested);
    } catch (_) {}
  }

  @override
  void didUpdateWidget(covariant DesktopShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.player != widget.player) {
      try {
        oldWidget.player.openLyricsSettingsRequest
            .removeListener(_onOpenLyricsSettingsRequested);
      } catch (_) {}
      try {
        widget.player.openLyricsSettingsRequest
            .addListener(_onOpenLyricsSettingsRequested);
      } catch (_) {}
    }
  }

  /// 侧栏条目点按：单击语义不变（切换分区/回内容根）；窗口时长内连点同一
  /// 条目视为双击当前分区，触发对应页面刷新。检测用手动计时窗口而非
  /// InkWell.onDoubleTap——否则 Flutter 为消歧会把每次单击推迟 ~300ms
  /// 才派发，侧栏切换会明显变钝。
  void _handleSidebarTap(int index) {
    // wasCurrent 取本分组在首次点按前的选中态：从其它分区双击一个条目，
    // 第一击已完成切换，第二击不再触发刷新（与移动端「点其它 tab 只切换」
    // 一致，切换本身就会带出各分区保留的内容）。
    final wasCurrent = index == _sidebarIndex;
    _selectSection(index);
    final now = desktopShellNow();
    if (wasCurrent &&
        _lastSidebarTapIndex == index &&
        _lastSidebarTapTime != null &&
        now.difference(_lastSidebarTapTime!) < _sidebarDoubleClickInterval) {
      _lastSidebarTapIndex = null;
      _lastSidebarTapTime = null;
      // 只有首页三分区有刷新语义；我的音乐/已下载/设置双击只保留单击
      // 的回根行为（与移动端「我的」无刷新内容一致）。
      // 并行刷新：立即起刷新让均衡器当帧出现，回顶动画并行进行。
      if (index <= 2) {
        _homePageKey.currentState
            ?.scrollToTopAndRefresh(refreshInParallel: true);
      }
      return;
    }
    _lastSidebarTapIndex = index;
    _lastSidebarTapTime = now;
  }

  @override
  void dispose() {
    try {
      widget.player.openLyricsSettingsRequest
          .removeListener(_onOpenLyricsSettingsRequested);
    } catch (_) {}
    _searchController.dispose();
    _searchFocusNode.dispose();
    _tabsRevision.dispose();
    super.dispose();
  }

  Future<void> _restoreMainWindow() async {
    try {
      if (await windowManager.isMinimized()) {
        await windowManager.restore();
      }
      await windowManager.show();
      await windowManager.focus();
    } catch (e) {
      debugPrint('[DesktopShell] Failed to restore main window: $e');
    }
  }

  Future<void> _onOpenLyricsSettingsRequested() async {
    try {
      if (!widget.player.openLyricsSettingsRequest.value) return;
    } catch (_) {
      return;
    }
    if (widget.windowRestorer != null) {
      await widget.windowRestorer!();
    } else {
      await _restoreMainWindow();
    }
    if (!mounted) return;
    if (_lyricsSettingsPageOpen) return;
    _lyricsSettingsPageOpen = true;
    final route = MaterialPageRoute<void>(
      builder: (_) => DesktopLyricsSettingsPage(player: widget.player),
    );
    final inner = _contentNavKey.currentState;
    final Future<void> popped;
    if (inner != null) {
      popped = inner.push(route);
    } else {
      popped = Navigator.of(context).push(route);
    }
    popped.whenComplete(() {
      if (mounted) _lyricsSettingsPageOpen = false;
    });
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
    final targetSection = sidebarIndex <= 2
        ? _DesktopSection.home
        : _DesktopSection.values[sidebarIndex - 2];
    final targetHomeTab = sidebarIndex <= 2 ? sidebarIndex : _homeTab;
    // 点按已选中的首页子分区（含双击当前分区刷新的两击）：分区状态不变，
    // 只回内容根。此时不再 setState + _tabsRevision++——修订号会经
    // ValueListenableBuilder 把 LazyIndexedStack 里所有已访问分区整树
    // 重建一遍，恰与双击触发的分区刷新叠进同一帧，把顶部均衡器该出现
    // 的首帧挤掉（动画直到刷新结束才可见）。非首页分区保留原行为：
    // 「已下载」靠修订号变化在重复点按时重新对账下载索引。
    if (targetSection == _DesktopSection.home &&
        _section == _DesktopSection.home &&
        _homeTab == targetHomeTab) {
      return;
    }
    setState(() {
      _section = targetSection;
      _homeTab = targetHomeTab;
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
    _searchFocusNode.requestFocus();
    _searchController.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _searchController.text.length,
    );
    setState(() => _searchPanelOpen = true);
  }

  void _closeSearchPanel({bool unfocus = false}) {
    if (unfocus) _searchFocusNode.unfocus();
    if (_searchPanelOpen && mounted) {
      setState(() => _searchPanelOpen = false);
    }
  }

  void _submitSearch(String raw) {
    final query = raw.trim();
    if (query.isEmpty) return;
    _searchController.text = query;
    _closeSearchPanel(unfocus: true);
    final inner = _contentNavKey.currentState;
    final page = SearchPage(
      api: widget.api,
      auth: widget.auth,
      player: widget.player,
      initialQuery: query,
      embedded: true,
    );
    if (inner == null) {
      _pushContent(context, page);
      return;
    }
    // 不 popUntil 根：保留用户原先的内容栈（如歌单详情），返回即回上一页。
    // 仅当栈顶仍是搜索页（跟踪的路由 isCurrent）时 replace，避免连搜叠层；
    // 搜索页上方若有详情页则正常 push，replace 会把用户正在看的详情页换掉。
    final route = MaterialPageRoute<void>(builder: (_) => page);
    final Future<void> popped;
    final searchRoute = _searchRoute;
    if (searchRoute != null && searchRoute.isCurrent && inner.canPop()) {
      popped = inner.pushReplacement(route);
    } else {
      popped = inner.push(route);
    }
    _searchRoute = route;
    popped.whenComplete(() {
      // 只有完成的仍是当前跟踪的搜索路由才清位：pushReplacement 下旧路由
      // 的 popped 晚于新路由入栈才完成，不能误清新路由的标记。
      if (mounted && identical(_searchRoute, route)) {
        _searchRoute = null;
      }
    });
  }

  void _openPlayerPage(BuildContext context) {
    if (widget.player.currentSong == null) return;
    // 播放页是整屏路由：盖住标题栏，页内自带窗口控制浮层（拖拽条+三键）。
    // 必须推到根 Navigator——推入内层内容导航的话标题栏仍然可见，会出现
    // 双份窗口按钮。与播放栏空白处点击同一条路径，保证入口行为一致。
    PlayerPageRoute.open(context, player: widget.player, auth: widget.auth);
  }

  /// 搜索浮层顶部"听歌识曲"入口：先收浮层，再推根 Navigator 整屏
  /// fullscreenDialog 识曲页（与移动端搜索页入口同款路由）。
  /// isSupported 闸门在浮层面板内部——不支持平台不渲染该行。
  void _openIdentify(BuildContext context) {
    _closeSearchPanel(unfocus: true);
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => IdentifyPage(player: widget.player),
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
    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.keyF, control: true):
            _OpenSearchIntent(),
        // Ctrl+1-6 直达侧栏分区：1-3 = 推荐/排行榜/电台，
        // 4-6 = 我的音乐/已下载/设置（与侧栏自上而下顺序一致）。
        SingleActivator(LogicalKeyboardKey.digit1, control: true):
            _SelectSidebarSectionIntent(0),
        SingleActivator(LogicalKeyboardKey.digit2, control: true):
            _SelectSidebarSectionIntent(1),
        SingleActivator(LogicalKeyboardKey.digit3, control: true):
            _SelectSidebarSectionIntent(2),
        SingleActivator(LogicalKeyboardKey.digit4, control: true):
            _SelectSidebarSectionIntent(3),
        SingleActivator(LogicalKeyboardKey.digit5, control: true):
            _SelectSidebarSectionIntent(4),
        SingleActivator(LogicalKeyboardKey.digit6, control: true):
            _SelectSidebarSectionIntent(5),
        SingleActivator(LogicalKeyboardKey.enter):
            _OpenPlayerIntent(),
        SingleActivator(LogicalKeyboardKey.numpadEnter):
            _OpenPlayerIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _OpenSearchIntent: GuardedCallbackAction<_OpenSearchIntent>(
            desktop: true,
            guard: (_) => isFocusInsideInteractiveControl(),
            onInvoke: (_) {
              _openSearch(context);
              return null;
            },
          ),
          _SelectSidebarSectionIntent:
              GuardedCallbackAction<_SelectSidebarSectionIntent>(
            desktop: true,
            guard: (_) => isFocusInsideInteractiveControl(),
            onInvoke: (intent) {
              _selectSection(intent.index);
              return null;
            },
          ),
          _OpenPlayerIntent: GuardedCallbackAction<_OpenPlayerIntent>(
            desktop: true,
            guard: (_) => isFocusInsideInteractiveControl(),
            onInvoke: (_) {
              _openPlayerPage(context);
              return null;
            },
          ),
        },
        child: Scaffold(
          body: Stack(
            children: [
              Column(
                children: [
                  DesktopTitleBar(
                    controller: _searchController,
                    focusNode: _searchFocusNode,
                    onFocusChanged: (focused) {
                      if (focused) {
                        setState(() => _searchPanelOpen = true);
                      }
                    },
                    onSubmitted: _submitSearch,
                    onEscape: () => _closeSearchPanel(unfocus: true),
                    onChromeTap: () => _closeSearchPanel(unfocus: true),
                  ),
                  const Divider(height: 1, thickness: 1),
                  Expanded(
                    child: Row(
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
                          onSelect: _handleSidebarTap,
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
                                          contentIndexProvider: () =>
                                              _contentIndex,
                                          homePageKey: _homePageKey,
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
                              DesktopPlayerBar(
                                player: widget.player,
                                auth: widget.auth,
                                onOpenPlayerPage: () =>
                                    _openPlayerPage(context),
                                // 评论/歌手等详情页推入内容区 Navigator，保留侧栏；
                                // 根 Navigator 会整窗全屏盖住侧栏。
                                onOpenComment: (mixsongid) => _pushContent(
                                  context,
                                  CommentPage(
                                    api: widget.api,
                                    mixsongid: mixsongid,
                                  ),
                                ),
                                onOpenArtist: (artist) => _pushContent(
                                  context,
                                  ArtistDetailPage(
                                    api: widget.api,
                                    auth: widget.auth,
                                    artist: artist,
                                    player: widget.player,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              // 顶栏搜索浮层：点击内容区收起；标题栏保持可输入。
              if (_searchPanelOpen) ...[
                Positioned(
                  top: kDesktopTitleBarHeight + 1,
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: () => _closeSearchPanel(unfocus: true),
                    child: const ColoredBox(color: Colors.transparent),
                  ),
                ),
                Positioned(
                  top: kDesktopTitleBarHeight,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 520),
                      child: DesktopSearchSuggestPanel(
                        api: widget.api,
                        onKeywordTap: _submitSearch,
                        onOpenIdentify: () => _openIdentify(context),
                      ),
                    ),
                  ),
                ),
              ],
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

/// Ctrl+1-6：选择侧栏分区（0-2 = 首页三个子 tab，3-5 = 我的音乐/已下载/设置）。
class _SelectSidebarSectionIntent extends Intent {
  const _SelectSidebarSectionIntent(this.index);
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
    required this.homePageKey,
    required this.api,
    required this.auth,
    required this.player,
    required this.cache,
    required this.downloads,
    required this.theme,
    required this.localMusic,
    required this.onHomeTabSwitch,
  });

  /// 「已下载」页在 LazyIndexedStack.children 中的下标（与下方 children
  /// 列表顺序绑定，插拔分区时需同步）。保活栈里该页靠本下标 + revision
  /// 感知"重新成为当前分区"，触发下载索引对账（外部删除同步）。
  static const int downloadsContentIndex = 2;

  final ValueNotifier<int> revision;
  final _DesktopSection Function() sectionProvider;
  final int Function() homeTabProvider;
  final int Function() contentIndexProvider;

  /// 透传给 [HomePage] 的 GlobalKey：供 shell 侧栏双击当前分区时调用
  /// HomePageState.scrollToTopAndRefresh（回顶 + 刷新 + 顶部均衡器）。
  final GlobalKey<HomePageState> homePageKey;
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
              key: homePageKey,
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
            DownloadedSongsPage(
              api: api,
              auth: auth,
              player: player,
              downloads: downloads,
              // 保活栈不重建页面：切回本分区时靠 revision 重新对账下载索引
              activationRevision: revision,
              isActive: () =>
                  contentIndexProvider() == downloadsContentIndex,
            ),
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
