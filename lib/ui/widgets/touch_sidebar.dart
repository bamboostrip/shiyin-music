import 'package:flutter/material.dart';

import '../../controllers/auth_controller.dart';
import '../../controllers/player_controller.dart';
import '../form_factor.dart';
import '../player/player_route.dart';
import 'artwork.dart';

/// 触屏侧栏条目描述。
class TouchSidebarItem {
  const TouchSidebarItem({
    required this.icon,
    required this.activeIcon,
    required this.label,
  });

  final IconData icon;
  final IconData activeIcon;
  final String label;
}

/// 平板触屏侧栏：移动形态宽屏（≥ [AdaptiveLayout.kTouchSidebarStartWidth]）
/// 的左侧导航，替代原 80dp NavigationRail。
///
/// 结构（QQ 音乐平板式）：顶部搜索入口胶囊 → 导航条目（推荐/排行榜/
/// 电台/我的，把首页三个子 tab 提升为一级）→ 底部停靠迷你播放器。
/// 条目视觉与桌面侧栏（DesktopSidebar）同语言：44 高、12 圆角、选中
/// primary@.12 底。纯展示组件，选中态与回调全部由父级（AppShell）持有。
class TouchSidebar extends StatelessWidget {
  const TouchSidebar({
    super.key,
    required this.items,
    required this.selectedIndex,
    required this.onSelect,
    required this.onSearchTap,
    required this.player,
    required this.auth,
  });

  final List<TouchSidebarItem> items;
  final int selectedIndex;
  final ValueChanged<int> onSelect;
  final VoidCallback onSearchTap;

  final PlayerController player;
  final AuthController auth;

  static const double width = 208;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final topInset = MediaQuery.paddingOf(context).top;

    return SizedBox(
      width: width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 搜索入口胶囊：样式与车机顶栏搜索药丸同语言（描边浅底胶囊）。
          Padding(
            padding: EdgeInsets.fromLTRB(12, topInset + 8, 12, 4),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onSearchTap,
              child: Container(
                height: 44,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                decoration: BoxDecoration(
                  color: isDark
                      ? colorScheme.surfaceContainerHighest
                      : colorScheme.surfaceContainerHighest.withValues(
                          alpha: .54,
                        ),
                  borderRadius: BorderRadius.circular(22),
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
                      size: 20,
                      color: isDark
                          ? colorScheme.onSurface.withValues(alpha: .92)
                          : colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '搜索',
                      style: TextStyle(
                        fontSize: 14,
                        color: isDark
                            ? colorScheme.onSurface.withValues(alpha: .62)
                            : colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 4,
              ),
              children: [
                for (final (index, item) in items.indexed)
                  _TouchSidebarTile(
                    item: item,
                    selected: index == selectedIndex,
                    colorScheme: colorScheme,
                    onTap: () => onSelect(index),
                  ),
              ],
            ),
          ),
          SidebarMiniPlayer(player: player, auth: auth),
        ],
      ),
    );
  }
}

class _TouchSidebarTile extends StatelessWidget {
  const _TouchSidebarTile({
    required this.item,
    required this.selected,
    required this.colorScheme,
    required this.onTap,
  });

  final TouchSidebarItem item;
  final bool selected;
  final ColorScheme colorScheme;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final foreground = selected
        ? colorScheme.primary
        : colorScheme.onSurfaceVariant;
    return Semantics(
      button: true,
      selected: selected,
      onTap: onTap,
      child: InkWell(
        onTap: onTap,
        excludeFromSemantics: true,
        borderRadius: BorderRadius.circular(12),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          height: 44,
          margin: const EdgeInsets.symmetric(vertical: 2),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: selected
                ? colorScheme.primary.withValues(alpha: .12)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Icon(
                selected ? item.activeIcon : item.icon,
                size: 22,
                color: foreground,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  item.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                    color: foreground,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 侧栏底部停靠的迷你播放器：封面 + 歌名/歌手 + 上一首/播放/下一首。
///
/// 与悬浮胶囊 [MiniPlayer] 同为 player 响应体，沿用其两处防护：
/// 车机模式由外层保证不渲染（本组件只挂在普通宽屏分支）；
/// Windows 引擎 AXTree 竞态用 [ExcludeSemantics] 规避。
/// 未播放时收起为空白，不占侧栏高度。
class SidebarMiniPlayer extends StatelessWidget {
  const SidebarMiniPlayer({
    super.key,
    required this.player,
    required this.auth,
  });

  final PlayerController player;
  final AuthController auth;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final bottomInset = MediaQuery.paddingOf(context).bottom;

    return ExcludeSemantics(
      excluding: isDesktopPlatform,
      child: AnimatedBuilder(
        animation: player,
        builder: (context, _) {
          final song = player.currentSong;
          if (song == null) return const SizedBox.shrink();
          return Padding(
            padding: EdgeInsets.fromLTRB(12, 4, 12, 8 + bottomInset),
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  InkWell(
                    onTap: () => PlayerPageRoute.open(
                      context,
                      player: player,
                      auth: auth,
                    ),
                    borderRadius: BorderRadius.circular(8),
                    child: Row(
                      children: [
                        Artwork(
                          url: song.coverUrl,
                          size: 44,
                          borderRadius: 8,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                song.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: colorScheme.onSurface,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                song.artist,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
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
                  const SizedBox(height: 2),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      IconButton(
                        tooltip: '上一首',
                        iconSize: 24,
                        visualDensity: VisualDensity.compact,
                        onPressed: player.previous,
                        icon: Icon(
                          Icons.skip_previous_rounded,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                      IconButton(
                        tooltip: player.isPlaying ? '暂停' : '播放',
                        iconSize: 32,
                        visualDensity: VisualDensity.compact,
                        onPressed: player.togglePlay,
                        icon: Icon(
                          player.isPlaying
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                          color: colorScheme.primary,
                        ),
                      ),
                      IconButton(
                        tooltip: '下一首',
                        iconSize: 24,
                        visualDensity: VisualDensity.compact,
                        onPressed: player.next,
                        icon: Icon(
                          Icons.skip_next_rounded,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
