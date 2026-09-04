import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// 把垂直滚轮增量转为子级横向滚动（PC 适配：免 Shift 横向滚动）。
///
/// [builder] 注入组件内部持有的 [ScrollController]，调用方把它接到
/// 自己的横向 ListView/SingleChildScrollView 上；组件随自身销毁释放。
/// 说明：滚轮落在横轨区域时事件被本组件消费，不会穿透给父级纵向滚动——
/// 需要滚动页面时把鼠标移出横轨即可（与主流桌面音乐软件一致）。
class HorizontalWheelScroll extends StatefulWidget {
  const HorizontalWheelScroll({super.key, required this.builder});

  final Widget Function(BuildContext context, ScrollController controller)
      builder;

  @override
  State<HorizontalWheelScroll> createState() => _HorizontalWheelScrollState();
}

class _HorizontalWheelScrollState extends State<HorizontalWheelScroll> {
  final _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerSignal: (event) => _scrollOnWheel(context, event, _controller),
      child: widget.builder(context, _controller),
    );
  }
}

/// 滚轮驱动既有 [PageView]（controller 传入其 PageController）。
///
/// pointerScroll 的增量由 PageView 的页面物理吸附，表现为滚轮翻页。
class HorizontalWheelPageScroll extends StatelessWidget {
  const HorizontalWheelPageScroll({
    super.key,
    required this.controller,
    required this.child,
  });

  final ScrollController controller;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerSignal: (event) => _scrollOnWheel(context, event, controller),
      child: child,
    );
  }
}

void _scrollOnWheel(
  BuildContext context,
  PointerSignalEvent event,
  ScrollController controller,
) {
  if (event is! PointerScrollEvent) return;
  final delta = event.scrollDelta.dy;
  if (delta == 0 || !controller.hasClients) return;
  final position = controller.position;
  if (position.maxScrollExtent <= 0) return;
  position.pointerScroll(delta);
}
