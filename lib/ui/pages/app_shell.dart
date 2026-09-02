import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../controllers/auth_controller.dart';
import '../../controllers/download_controller.dart';
import '../../controllers/player_controller.dart';
import '../../controllers/theme_controller.dart';
import '../../controllers/local_music_controller.dart';
import '../../services/cache_service.dart';
import '../../services/music_api.dart';
import '../widgets/artwork.dart';
import '../widgets/mini_player.dart';
import '../widgets/car_left_player_panel.dart';
import '../adaptive_layout.dart';
import 'home_page.dart';
import 'library_page.dart';
import 'player_page.dart';
import 'search_page.dart';
import 'settings_page.dart';

class AppShell extends StatefulWidget {
  const AppShell({
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
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  var _index = 1; // Default to '推荐' tab (index 1) in landscape
  var _lastHomeTab =
      1; // Tracks the last active Home sub-tab (1=推荐, 2=排行榜, 3=电台)
  final _navigatorKey = GlobalKey<NavigatorState>();

  int _getPortraitIndex() {
    return _index == 0 ? 1 : 0;
  }

  void _setPortraitIndex(int index) {
    setState(() {
      _index = index == 0 ? _lastHomeTab : 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    return AppShortcutScope(player: widget.player, child: _buildShell(context));
  }

  Widget _buildShell(BuildContext context) {
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final colorScheme = Theme.of(context).colorScheme;
    final size = MediaQuery.sizeOf(context);
    final isLandscape = size.width > size.height;

    // 车机布局：仅在横屏且开启车机模式时启用（左侧播放面板 + 顶栏）。
    // 关闭时回到普通布局（宽屏用 NavigationRail），与原项目行为一致；
    // 平板横屏适配留给上游后续开发。
    if (isLandscape && widget.theme.carModeEnabled) {
      // 车机模式下文字相对放大（保留系统无障碍设置）。
      final baseTextScaler = MediaQuery.textScalerOf(context);
      final scaledTextScaler = _RelativeTextScaler(
        base: baseTextScaler,
        multiplier: ThemeController.carModeFontScaleFactor,
      );
      return MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: scaledTextScaler),
        child: PopScope(
          // 拦截 Android 返回键：先尝试 pop 内层 Navigator（搜索/设置/歌单等
          // push 到内层 Navigator 的页面），内层无法 pop 时才退出应用。
          // 不加 PopScope 会导致返回键只 pop root Navigator（只有一个 AppShell
          // route），从歌单页面返回直接退出应用。
          canPop: false,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) return;
            final nav = _navigatorKey.currentState;
            if (nav != null && nav.canPop()) {
              nav.pop();
            } else {
              SystemNavigator.pop();
            }
          },
          child: Scaffold(
            body: Row(
              children: [
                // ExcludeSemantics 规避 CarLeftPlayerPanel 频繁响应 player 更新
                // 导致的 Windows AXTree 竞态崩溃（Flutter Windows 引擎 bug）
                ExcludeSemantics(
                  child: CarLeftPlayerPanel(
                    player: widget.player,
                    auth: widget.auth,
                  ),
                ),
                const VerticalDivider(width: 1, thickness: 1),
                Expanded(
                  child: Navigator(
                    key: _navigatorKey,
                    onGenerateRoute: (settings) {
                      return MaterialPageRoute(
                        builder: (navContext) {
                          final homePage = HomePage(
                            api: widget.api,
                            auth: widget.auth,
                            player: widget.player,
                            cache: widget.cache,
                            theme: widget.theme,
                            downloads: widget.downloads,
                            localMusic: widget.localMusic,
                            sectionIndex: _index > 0 ? _index - 1 : 0,
                            onTabSwitch: (index) {
                              setState(() {
                                _index = index;
                                if (index >= 1 && index <= 3) {
                                  _lastHomeTab = index;
                                }
                              });
                            },
                          );

                          final libraryPage = LibraryPage(
                            api: widget.api,
                            auth: widget.auth,
                            player: widget.player,
                            downloads: widget.downloads,
                            theme: widget.theme,
                            localMusic: widget.localMusic,
                          );

                          final pages = [homePage, libraryPage];
                          final activePageIndex = _index == 0 ? 1 : 0;

                          return Scaffold(
                            body: Column(
                              children: [
                                _buildCarTopNavBar(navContext),
                                const Divider(height: 1),
                                Expanded(
                                  child: _LazyIndexedStack(
                                    index: activePageIndex,
                                    children: pages,
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    // Original Portrait Layout
    final useNavRail = size.width >= 720;
    final portraitIndex = _getPortraitIndex();

    final homePage = HomePage(
      api: widget.api,
      auth: widget.auth,
      player: widget.player,
      cache: widget.cache,
      theme: widget.theme,
      downloads: widget.downloads,
      localMusic: widget.localMusic,
      sectionIndex: _index > 0 ? _index - 1 : 0,
      onTabSwitch: (index) {
        setState(() {
          _index = index;
          if (index >= 1 && index <= 3) {
            _lastHomeTab = index;
          }
        });
      },
    );

    final libraryPage = LibraryPage(
      api: widget.api,
      auth: widget.auth,
      player: widget.player,
      downloads: widget.downloads,
      theme: widget.theme,
      localMusic: widget.localMusic,
    );

    final pages = [homePage, libraryPage];

    Widget mainContent = Stack(
      children: [
        Positioned.fill(
          child: _LazyIndexedStack(index: portraitIndex, children: pages),
        ),
        if (useNavRail)
          Positioned(
            left: 0,
            right: 0,
            bottom: bottomInset + 16,
            child: MiniPlayer(player: widget.player, auth: widget.auth),
          ),
      ],
    );

    if (useNavRail) {
      mainContent = Row(
        children: [
          NavigationRail(
            selectedIndex: portraitIndex,
            onDestinationSelected: _setPortraitIndex,
            backgroundColor: colorScheme.surfaceContainerLow,
            labelType: NavigationRailLabelType.all,
            selectedIconTheme: IconThemeData(color: colorScheme.primary),
            unselectedIconTheme: IconThemeData(
              color: colorScheme.onSurfaceVariant,
            ),
            selectedLabelTextStyle: TextStyle(
              color: colorScheme.primary,
              fontWeight: FontWeight.w800,
            ),
            unselectedLabelTextStyle: TextStyle(
              color: colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
            destinations: const [
              NavigationRailDestination(
                icon: Icon(Icons.home_outlined),
                selectedIcon: Icon(Icons.home_rounded),
                label: Text('首页'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.person_outline_rounded),
                selectedIcon: Icon(Icons.person_rounded),
                label: Text('我的'),
              ),
            ],
          ),
          const VerticalDivider(width: 1, thickness: 1),
          Expanded(child: mainContent),
        ],
      );
    }

    return Scaffold(
      extendBody: true,
      body: AdaptiveContentPadding(child: mainContent),
      bottomNavigationBar: useNavRail
          ? null
          : _FloatingBottomBar(
              currentIndex: portraitIndex,
              onTap: _setPortraitIndex,
              player: widget.player,
              auth: widget.auth,
            ),
    );
  }

  Widget _buildCarTopNavBar(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final tabs = ['我的', '推荐', '排行榜', '电台'];
    final topInset = MediaQuery.paddingOf(context).top;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      // 顶部加上状态栏高度，避免导航栏内容被状态栏遮挡
      padding: EdgeInsets.fromLTRB(16, topInset, 16, 0),
      height: 72 + topInset, // Increased from 64
      child: Row(
        children: [
          // Search Pill Button — 已适配深色模式：深色下使用实色 + 边框提升对比度
          GestureDetector(
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => SearchPage(
                  api: widget.api,
                  auth: widget.auth,
                  player: widget.player,
                ),
              ),
            ),
            child: Container(
              height: 46, // Increased from 38
              padding: const EdgeInsets.symmetric(
                horizontal: 20,
              ), // Increased from 16
              decoration: BoxDecoration(
                color: isDark
                    ? colorScheme.surfaceContainerHighest
                    : colorScheme.surfaceContainerHighest.withValues(
                        alpha: .54,
                      ),
                borderRadius: BorderRadius.circular(
                  23,
                ), // Increased from 19 (height/2)
                border: Border.all(
                  color: isDark
                      ? colorScheme.outlineVariant.withValues(alpha: .85)
                      : colorScheme.outlineVariant.withValues(alpha: .45),
                  width: 1,
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.search_rounded,
                    color: isDark
                        ? colorScheme.onSurface.withValues(alpha: .92)
                        : colorScheme.onSurfaceVariant,
                    size: 22, // Increased from 20
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '搜索',
                    style: TextStyle(
                      color: isDark
                          ? colorScheme.onSurface.withValues(alpha: .92)
                          : colorScheme.onSurfaceVariant,
                      fontSize: 16, // Increased from default
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 32), // Increased from 24
          // Choice Chip Tabs
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final entry in tabs.indexed)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                      ), // Increased from 6
                      child: ChoiceChip(
                        showCheckmark: false,
                        label: Text(
                          entry.$2,
                          style: TextStyle(
                            fontSize: 17, // Increased from default
                            fontWeight: _index == entry.$1
                                ? FontWeight.w900
                                : FontWeight.w600,
                          ),
                        ),
                        selected: _index == entry.$1,
                        onSelected: (selected) {
                          if (selected) {
                            setState(() {
                              _index = entry.$1;
                              if (entry.$1 >= 1 && entry.$1 <= 3) {
                                _lastHomeTab = entry.$1;
                              }
                            });
                          }
                        },
                        selectedColor: colorScheme.primary.withValues(
                          alpha: 0.18,
                        ),
                        labelStyle: TextStyle(
                          color: _index == entry.$1
                              ? colorScheme.primary
                              : colorScheme.onSurfaceVariant,
                        ),
                        backgroundColor: Colors.transparent,
                        side: BorderSide.none,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ), // Added explicit padding
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(
                            12,
                          ), // Added explicit shape for larger tap area
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          // Settings Icon
          IconButton(
            tooltip: '设置',
            iconSize: 28, // Increased iconSize from default (24)
            icon: const Icon(Icons.settings_rounded),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => SettingsPage(
                    api: widget.api,
                    auth: widget.auth,
                    player: widget.player,
                    theme: widget.theme,
                    downloads: widget.downloads,
                    cache: widget.cache,
                    localMusic: widget.localMusic,
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

/// 悬浮胶囊底栏（实色，无 BackdropFilter）— 参考上游 ` _LiquidGlassBottomBar` 的居中唱片交互，
/// 但以实色 + 轻阴影实现，避免 `ImageFilter.blur` 在车机/低端机上的离屏缓冲与掉帧。
class _FloatingBottomBar extends StatelessWidget {
  const _FloatingBottomBar({
    required this.currentIndex,
    required this.onTap,
    required this.player,
    required this.auth,
  });

  final int currentIndex;
  final ValueChanged<int> onTap;
  final PlayerController player;
  final AuthController auth;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bottomInset = MediaQuery.paddingOf(context).bottom;

    return Align(
      alignment: Alignment.bottomCenter,
      child: Padding(
        padding: EdgeInsets.fromLTRB(24, 0, 24, bottomInset > 0 ? bottomInset : 12),
        child: Container(
          height: 62,
          constraints: const BoxConstraints(maxWidth: 380),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF1E2433) : Colors.white,
            borderRadius: BorderRadius.circular(32),
            border: Border.all(
              color: isDark
                  ? Colors.white.withValues(alpha: .12)
                  : colorScheme.outlineVariant.withValues(alpha: .5),
              width: 1,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: isDark ? .28 : .12),
                blurRadius: 18,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Row(
            children: [
              _BottomNavItem(
                icon: Icons.home_outlined,
                activeIcon: Icons.home_rounded,
                label: '首页',
                selected: currentIndex == 0,
                onTap: () => onTap(0),
              ),
              _CenterDisc(player: player, auth: auth),
              _BottomNavItem(
                icon: Icons.person_outline_rounded,
                activeIcon: Icons.person_rounded,
                label: '我的',
                selected: currentIndex == 1,
                onTap: () => onTap(1),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BottomNavItem extends StatelessWidget {
  const _BottomNavItem({
    required this.icon,
    required this.activeIcon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final IconData activeIcon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              selected ? activeIcon : icon,
              size: 24,
              color: selected ? colorScheme.primary : colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                color: selected ? colorScheme.primary : colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CenterDisc extends StatelessWidget {
  const _CenterDisc({required this.player, required this.auth});

  final PlayerController player;
  final AuthController auth;

  void _openPlayer(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => PlayerPage(player: player, auth: auth)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: () => _openPlayer(context),
      onLongPress: () {
        if (player.currentSong != null) {
          HapticFeedback.lightImpact();
          player.togglePlay();
        }
      },
      child: AnimatedBuilder(
        animation: player,
        builder: (context, _) {
          final song = player.currentSong;
          final hasSong = song != null;
          final durationMs = player.duration.inMilliseconds;
          final positionMs = player.position.inMilliseconds;
          final progress = (durationMs > 0 ? positionMs / durationMs : 0.0).clamp(0.0, 1.0);
          return SizedBox(
            width: 52,
            height: 52,
            child: Stack(
              alignment: Alignment.center,
              children: [
                // 进度环
                SizedBox(
                  width: 52,
                  height: 52,
                  child: CircularProgressIndicator(
                    value: hasSong ? progress : 0,
                    strokeWidth: 2.5,
                    backgroundColor: colorScheme.outlineVariant.withValues(alpha: .35),
                    valueColor: AlwaysStoppedAnimation<Color>(colorScheme.primary),
                  ),
                ),
                // 封面
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white.withValues(alpha: .9), width: 1.5),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: .15),
                        blurRadius: 6,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: ClipOval(
                    child: hasSong
                        ? Artwork(url: song.coverUrl, size: 42, borderRadius: 21)
                        : Container(
                            color: colorScheme.surfaceContainerHighest,
                            child: Icon(Icons.music_note_rounded,
                                size: 22, color: colorScheme.onSurfaceVariant),
                          ),
                  ),
                ),
                // 播放/暂停小图标叠加（无歌时隐藏）
                if (hasSong)
                  Container(
                    width: 18,
                    height: 18,
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: .45),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      player.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                      size: 12,
                      color: Colors.white,
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// 只在首次被选中时才构建对应 child 的 [IndexedStack]。
///
/// 普通 IndexedStack 会一次性构建全部 children，导致所有页面
/// 都在 initState 中发起网络请求。这里通过懒构建
/// 保证只有被访问过的 tab 才会真正初始化，避免重复请求与重复监听。
class _LazyIndexedStack extends StatefulWidget {
  const _LazyIndexedStack({required this.index, required this.children});

  final int index;
  final List<Widget> children;

  @override
  State<_LazyIndexedStack> createState() => _LazyIndexedStackState();
}

class _LazyIndexedStackState extends State<_LazyIndexedStack> {
  final _built = <int>{};

  @override
  void initState() {
    super.initState();
    _built.add(widget.index);
  }

  @override
  void didUpdateWidget(covariant _LazyIndexedStack oldWidget) {
    super.didUpdateWidget(oldWidget);
    _built.add(widget.index);
  }

  @override
  Widget build(BuildContext context) {
    return IndexedStack(
      index: widget.index,
      children: [
        for (var i = 0; i < widget.children.length; i++)
          _built.contains(i) ? widget.children[i] : const SizedBox.shrink(),
      ],
    );
  }
}

/// 在已有 [TextScaler] 基础上再乘固定倍数（Flutter 内置 TextScaler 无 `*` 运算符）。
class _RelativeTextScaler extends TextScaler {
  const _RelativeTextScaler({required this.base, required this.multiplier});

  final TextScaler base;
  final double multiplier;

  @override
  double scale(double fontSize) => base.scale(fontSize) * multiplier;

  @override
  double get textScaleFactor {
    // ignore: deprecated_member_use
    final baseFactor = base.textScaleFactor;
    return baseFactor * multiplier;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _RelativeTextScaler &&
          base == other.base &&
          multiplier == other.multiplier;

  @override
  int get hashCode => Object.hash(base, multiplier);

  @override
  String toString() => '$base × $multiplier';
}

/// 全局快捷键作用域（桌面端）：空格播放/暂停，左右键切歌。
class AppShortcutScope extends StatelessWidget {
  const AppShortcutScope({
    super.key,
    required this.player,
    required this.child,
  });

  final PlayerController player;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: {
        const SingleActivator(LogicalKeyboardKey.space):
            const _PlayPauseIntent(),
        const SingleActivator(LogicalKeyboardKey.arrowRight):
            const _NextIntent(),
        const SingleActivator(LogicalKeyboardKey.arrowLeft):
            const _PreviousIntent(),
      },
      child: Actions(
        actions: {
          _PlayPauseIntent: CallbackAction<_PlayPauseIntent>(
            onInvoke: (_) {
              if (!_isFocusInsideInteractiveControl()) player.togglePlay();
              return null;
            },
          ),
          _NextIntent: CallbackAction<_NextIntent>(
            onInvoke: (_) {
              if (!_isFocusInsideInteractiveControl()) player.next();
              return null;
            },
          ),
          _PreviousIntent: CallbackAction<_PreviousIntent>(
            onInvoke: (_) {
              if (!_isFocusInsideInteractiveControl()) player.previous();
              return null;
            },
          ),
        },
        child: Focus(autofocus: true, child: child),
      ),
    );
  }

  /// 焦点位于输入框或按钮等可交互控件内时返回 true。
  ///
  /// 此时应忽略全局快捷键，让按键落到默认行为（编辑文本/激活按钮）上。
  bool _isFocusInsideInteractiveControl() {
    final focused = FocusManager.instance.primaryFocus;
    if (focused == null || focused.context == null) return false;
    var interactive = false;
    focused.context!.visitAncestorElements((element) {
      final widget = element.widget;
      if (widget is EditableText ||
          widget is SelectableText ||
          widget is ButtonStyleButton ||
          widget is IconButton ||
          widget is RawMaterialButton) {
        interactive = true;
        return false;
      }
      return true;
    });
    return interactive;
  }
}

class _PlayPauseIntent extends Intent {
  const _PlayPauseIntent();
}

class _NextIntent extends Intent {
  const _NextIntent();
}

class _PreviousIntent extends Intent {
  const _PreviousIntent();
}
