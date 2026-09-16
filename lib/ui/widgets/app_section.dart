import 'package:flutter/material.dart';

import '../adaptive_layout.dart';
import 'horizontal_wheel_scroll.dart';

/// 统一的分区标题（标题 + 可选尾部操作）。
class AppSectionHeader extends StatelessWidget {
  const AppSectionHeader({
    super.key,
    required this.title,
    this.action,
    this.onTap,
  });

  final String title;
  final Widget? action;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    Widget titleWidget = Text(
      title,
      style: Theme.of(context).textTheme.titleMedium?.copyWith(
        fontSize: 18,
        fontWeight: FontWeight.w900,
        color: Theme.of(context).colorScheme.onSurface,
      ),
    );

    Widget? effectiveAction = action;
    if (onTap != null && effectiveAction == null) {
      effectiveAction = Icon(
        Icons.chevron_right_rounded,
        size: 22,
        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.55),
      );
    }

    final content = Row(
      children: [
        Expanded(child: titleWidget),
        ?effectiveAction,
      ],
    );

    if (onTap != null) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: content,
      );
    }
    return content;
  }
}

/// 通用横向卡片列表（标题 + 横向滚动）。
class AppHorizontalRail<T> extends StatelessWidget {
  const AppHorizontalRail({
    super.key,
    required this.title,
    required this.items,
    required this.height,
    required this.itemBuilder,
    this.itemWidth,
    this.padding = const EdgeInsets.symmetric(horizontal: 18),
    this.separatorWidth = 12,
    this.action,
    this.onTapTitle,
    this.topPadding = 20,
    this.headerPadding,
  });

  final String title;
  final List<T> items;
  final double height;
  final double? itemWidth;
  final Widget Function(BuildContext context, T item) itemBuilder;
  final EdgeInsetsGeometry padding;
  final double separatorWidth;
  final Widget? action;
  final VoidCallback? onTapTitle;
  final double topPadding;
  final EdgeInsetsGeometry? headerPadding;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        // 宽内容区（桌面宽窗 / 平板侧栏形态）：横轨转网格，
        // 列数随宽度收敛（设计 §3/§5）。
        final wide = AdaptiveLayout.isGridWidth(constraints.maxWidth);
        return Padding(
          padding: EdgeInsets.only(top: topPadding),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: headerPadding ?? padding,
                child: AppSectionHeader(
                  title: title,
                  action: action,
                  onTap: onTapTitle,
                ),
              ),
              const SizedBox(height: 12),
              if (wide)
                // 桌面宽窗：横轨转网格，列数随宽度收敛（设计 §3/§5）。
                GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  padding: padding,
                  itemCount: items.length,
                  gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: (itemWidth ?? 110) * 2 + separatorWidth,
                    mainAxisSpacing: separatorWidth,
                    crossAxisSpacing: separatorWidth,
                    mainAxisExtent: height,
                  ),
                  itemBuilder: (context, index) {
                    final child = itemBuilder(context, items[index]);
                    return MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: child,
                    );
                  },
                )
              else
                SizedBox(
                  height: height,
                  child: HorizontalWheelScroll(
                    builder: (context, controller) => ListView.separated(
                      controller: controller,
                      scrollDirection: Axis.horizontal,
                      padding: padding,
                      itemCount: items.length,
                      separatorBuilder: (_, _) =>
                          SizedBox(width: separatorWidth),
                      itemBuilder: (context, index) {
                        final item = items[index];
                        final child = itemBuilder(context, item);
                        final sized = itemWidth == null
                            ? child
                            : SizedBox(width: itemWidth, child: child);
                        // 桌面端显示手型光标，增强可点击感知。
                        return MouseRegion(
                          cursor: SystemMouseCursors.click,
                          child: sized,
                        );
                      },
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
