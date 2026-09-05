import 'package:flutter/material.dart';

/// 侧栏条目描述。[showDividerAbove] 为 true 时在该条目上方加分隔线
/// （用于把"设置"与导航区隔开）。
class DesktopNavItem {
  const DesktopNavItem({
    required this.icon,
    required this.activeIcon,
    required this.label,
    this.showDividerAbove = false,
  });

  final IconData icon;
  final IconData activeIcon;
  final String label;
  final bool showDividerAbove;
}

/// 桌面侧栏：搜索胶囊 + 导航条目。
///
/// 纯展示组件：选中态与回调全部由父级（DesktopShell）持有。
class DesktopSidebar extends StatelessWidget {
  const DesktopSidebar({
    super.key,
    required this.items,
    required this.selectedIndex,
    required this.onSelect,
    required this.onSearch,
  });

  final List<DesktopNavItem> items;
  final int selectedIndex;
  final ValueChanged<int> onSelect;
  final VoidCallback onSearch;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return SizedBox(
      width: 208,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
            child: _SearchPill(
              isDark: isDark,
              colorScheme: colorScheme,
              onTap: onSearch,
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              children: [
                for (final (index, item) in items.indexed) ...[
                  if (item.showDividerAbove)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Divider(
                        height: 1,
                        thickness: 1,
                        color: colorScheme.outlineVariant.withValues(alpha: .4),
                      ),
                    ),
                  _NavItemTile(
                    item: item,
                    selected: index == selectedIndex,
                    colorScheme: colorScheme,
                    onTap: () => onSelect(index),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SearchPill extends StatefulWidget {
  const _SearchPill({
    required this.isDark,
    required this.colorScheme,
    required this.onTap,
  });

  final bool isDark;
  final ColorScheme colorScheme;
  final VoidCallback onTap;

  @override
  State<_SearchPill> createState() => _SearchPillState();
}

class _SearchPillState extends State<_SearchPill> {
  var _focused = false;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: widget.onTap,
      borderRadius: BorderRadius.circular(21),
      onFocusChange: (focused) => setState(() => _focused = focused),
      child: Container(
        height: 42,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: widget.colorScheme.surfaceContainerHighest
              .withValues(alpha: widget.isDark ? 1 : .54),
          borderRadius: BorderRadius.circular(21),
          border: Border.all(
            color: widget.colorScheme.outlineVariant
                .withValues(alpha: widget.isDark ? .85 : .45),
            width: 1,
          ),
        ),
        // 键盘焦点环：画在内容之上，不影响布局与既有 hover 样式。
        foregroundDecoration: BoxDecoration(
          borderRadius: BorderRadius.circular(21),
          border: Border.all(
            color: _focused
                ? widget.colorScheme.primary.withValues(alpha: .75)
                : Colors.transparent,
            width: 1.5,
          ),
        ),
        child: Row(
          children: [
            Icon(
              Icons.search_rounded,
              size: 20,
              color: widget.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 8),
            Text(
              '搜索音乐',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: widget.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NavItemTile extends StatefulWidget {
  const _NavItemTile({
    required this.item,
    required this.selected,
    required this.colorScheme,
    required this.onTap,
  });

  final DesktopNavItem item;
  final bool selected;
  final ColorScheme colorScheme;
  final VoidCallback onTap;

  @override
  State<_NavItemTile> createState() => _NavItemTileState();
}

class _NavItemTileState extends State<_NavItemTile> {
  var _hovering = false;
  var _focused = false;

  @override
  Widget build(BuildContext context) {
    final selected = widget.selected;
    final foreground = selected
        ? widget.colorScheme.primary
        : widget.colorScheme.onSurfaceVariant;
    return Semantics(
      button: true,
      onTap: widget.onTap,
      child: InkWell(
        onTap: widget.onTap,
        excludeFromSemantics: true, // 语义由外层 Semantics 提供，避免重复
        borderRadius: BorderRadius.circular(12),
        // 视觉全部由下方容器自绘；InkWell 的 ink 反馈全部透明，
        // 保证既有 hover 样式不被叠加的默认色改变。
        // InkWell 只负责：Tab 焦点可达、Enter/Space 激活（ActivateIntent）、
        // 悬停回调与点击光标。
        splashColor: Colors.transparent,
        highlightColor: Colors.transparent,
        hoverColor: Colors.transparent,
        focusColor: Colors.transparent,
        mouseCursor: SystemMouseCursors.click,
        onHover: (hovering) => setState(() => _hovering = hovering),
        onFocusChange: (focused) => setState(() => _focused = focused),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          height: 44,
          margin: const EdgeInsets.symmetric(vertical: 2),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: selected
                ? widget.colorScheme.primary.withValues(alpha: .12)
                : _hovering
                    ? widget.colorScheme.surfaceContainerHigh
                    : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
          ),
          // 键盘焦点环：画在内容之上，不影响布局与 hover 样式。
          foregroundDecoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: _focused
                  ? widget.colorScheme.primary.withValues(alpha: .75)
                  : Colors.transparent,
              width: 1.5,
            ),
          ),
          child: Row(
            children: [
              Icon(
                selected ? widget.item.activeIcon : widget.item.icon,
                size: 22,
                color: foreground,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  widget.item.label,
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
