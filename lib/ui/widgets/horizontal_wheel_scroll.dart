import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// 把垂直滚轮增量转为子级横向滚动（PC 适配：免 Shift 横向滚动）。
///
/// [builder] 注入组件内部持有的 [ScrollController]，调用方把它接到
/// 自己的横向 ListView/SingleChildScrollView 上；组件随自身销毁释放。
/// 滚轮落在横轨区域且可朝该方向滚动时由本组件消费（经
/// [PointerSignalResolver] 注册，不会连带外层纵向滚动）；轨道不可滚
/// 或已到目标方向边缘时不接管事件，滚轮自然放行给外层纵向滚动
/// （见 [horizontalWheelConsumes]），不再出现"滚轮被卡住"的体验。
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
      onPointerSignal: (event) => _scrollOnWheel(event, _controller),
      child: widget.builder(context, _controller),
    );
  }
}

/// 滚轮驱动既有 [PageView]（controller 传入其 PageController）。
///
/// pointerScroll 的增量由 PageView 的页面物理吸附，表现为滚轮翻页；
/// 已在首/末页时同样放行给外层纵向滚动。
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
      onPointerSignal: (event) => _scrollOnWheel(event, controller),
      child: child,
    );
  }
}

/// 滚轮"消费 / 放行"判定（纯函数，便于单测）。
///
/// 返回 true 表示横向轨道本次应消费滚轮（可朝 [delta] 方向继续滚动）；
/// 返回 false 表示轨道未挂载、不可滚动（[maxScrollExtent] <= 0）或已到
/// 目标方向边缘（容差 [epsilon]），应放行给外层纵向滚动。
bool horizontalWheelConsumes({
  required double delta,
  required bool hasClients,
  required double maxScrollExtent,
  required double pixels,
  double epsilon = 0.5,
}) {
  if (delta == 0) return false;
  if (!hasClients || maxScrollExtent <= 0) return false;
  if (delta > 0) return pixels < maxScrollExtent - epsilon;
  return pixels > epsilon;
}

void _scrollOnWheel(
  PointerSignalEvent event,
  ScrollController controller,
) {
  if (event is! PointerScrollEvent) return;
  final delta = event.scrollDelta.dy;
  if (delta == 0 || !controller.hasClients) return;
  final position = controller.position;
  if (!horizontalWheelConsumes(
    delta: delta,
    hasClients: true,
    maxScrollExtent: position.maxScrollExtent,
    pixels: position.pixels,
  )) {
    // 轨道不可滚或已到目标方向边缘：不接管 = 放行。
    //
    // 本组件的 Listener 回调是事件分发期间的直接调用（不经 resolver），
    // 在这里"什么都不做"即等于不吞事件：横向 Scrollable 对垂直滚轮
    // 天然不感兴趣（其 delta 取 scrollDelta.dx，垂直滚轮恒为 0，不会注册），
    // 外层纵向 Scrollable 会经 PointerSignalResolver 接管并自行滚动。
    // 注意不能在这里手动 pointerScroll 外层 Position —— 外层稍后还会通过
    // resolver 滚一次，手动转发会造成双重滚动（实测验证过）。
    return;
  }
  // 可滚方向：注册为 resolver 的首个关心者（内层回调先于外层 Scrollable
  // 执行，必能抢到），滚动延迟到 resolve 阶段执行 —— 这样外层纵向
  // Scrollable 的注册会被忽略，整棵树只产生一次滚动，页面不会跟着动。
  GestureBinding.instance.pointerSignalResolver.register(event, (
    resolvedEvent,
  ) {
    if (resolvedEvent is PointerScrollEvent) {
      position.pointerScroll(resolvedEvent.scrollDelta.dy);
    }
  });
}
