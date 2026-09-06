import 'package:flutter/material.dart';

import '../form_factor.dart';

/// PC hover 反馈容器：鼠标悬停时显示底色 + 手型光标。
///
/// 包在歌曲行等可点击行外面，悬停即给用户“可点”反馈；
/// 非桌面形态（触屏永不触发）直接返回 child，省一层 MouseRegion
/// 与 Stateful 开销。
class HoverRow extends StatefulWidget {
  const HoverRow({
    super.key,
    required this.hoverColor,
    required this.child,
    this.borderRadius,
    this.cursor = SystemMouseCursors.click,
  });

  final Color hoverColor;
  final Widget child;
  final BorderRadius? borderRadius;
  final MouseCursor cursor;

  @override
  State<HoverRow> createState() => _HoverRowState();
}

class _HoverRowState extends State<HoverRow> {
  var _hovering = false;

  @override
  Widget build(BuildContext context) {
    if (!isDesktopFormFactor) return widget.child;
    return MouseRegion(
      cursor: widget.cursor,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        decoration: BoxDecoration(
          color: _hovering ? widget.hoverColor : Colors.transparent,
          borderRadius: widget.borderRadius ?? BorderRadius.circular(14),
        ),
        child: widget.child,
      ),
    );
  }
}
