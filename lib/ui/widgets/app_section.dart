import 'package:flutter/material.dart';

/// 统一的分区标题（标题 + 可选尾部操作）。
class AppSectionHeader extends StatelessWidget {
  const AppSectionHeader({super.key, required this.title, this.action});

  final String title;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontSize: 18,
              fontWeight: FontWeight.w900,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
        ),
        ?action,
      ],
    );
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
  final double topPadding;
  final EdgeInsetsGeometry? headerPadding;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.only(top: topPadding),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: headerPadding ?? padding,
            child: AppSectionHeader(title: title, action: action),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: height,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: padding,
              itemCount: items.length,
              separatorBuilder: (_, _) => SizedBox(width: separatorWidth),
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
        ],
      ),
    );
  }
}
