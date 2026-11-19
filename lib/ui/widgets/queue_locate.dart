// lib/ui/widgets/queue_locate.dart
import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 播放队列面板「定位到正在播放行」的滚动控制（issue #28）。
///
/// 职责纯滚动，不感知 PlayerController：
/// - 构造时按标称行步长估算 [controller] 的初始偏移（假定视口 360 居中，
///   只求首帧落点接近，误差由校正兜底）；
/// - 队列面板在带入场动画的 modal 底部弹层里，动画期间视口高度在变，
///   [correctWhenEntranceSettled] 等路由动画播完后再校正（无动画/已播完
///   则下一帧立即），[locate] 供头部定位按钮；
/// - 两者同走两段式：第一段按**实测行步长**（懒构建 sliver 的内容总长
///   / 行数，字体缩放下行高变大也能收敛）jump 到居中估算位，等一帧让
///   目标行挂载，仍未挂载则重估重跳（上限 3 轮）；第二段
///   `ensureVisible` 精修居中（[locate] 平滑 ~250ms，校正无动画）。
///
/// 列表是懒构建的：目标行滚出视口 + 缓存区后 context 即被卸载，
/// 第一段估算 jump 不依赖挂载，保证无论挂载与否都能落到位。
class QueueLocateController {
  QueueLocateController({
    required double rowStride,
    int? initialIndex,
    double assumedViewportExtent = 360,
  })  : _rowStride = rowStride,
        controller = ScrollController(
          // 目标行中心对准假定视口中心；360 为手机弹层列表区典型高度，
          // 减小入场结束后的可见校正跳变量。
          initialScrollOffset: initialIndex == null || initialIndex < 0
              ? 0
              : math.max(0.0, (initialIndex + 0.5) * rowStride - assumedViewportExtent / 2),
        );

  /// 第一段 jump 等待目标行挂载的最大轮数（行均匀缩放一轮即收敛）。
  static const int _maxJumpRounds = 3;

  final double _rowStride;
  final ScrollController controller;

  /// 精确校正：目标行 [rowKey] 居中。宿主在首帧后的回调里调用。
  void correctWhenEntranceSettled(
    Animation<double>? entrance,
    GlobalKey rowKey, {
    required int index,
    required int itemCount,
  }) {
    if (entrance == null || entrance.isCompleted) {
      _scheduleCorrection(rowKey, index: index, itemCount: itemCount);
      return;
    }
    void listener(AnimationStatus status) {
      switch (status) {
        case AnimationStatus.completed:
          entrance.removeStatusListener(listener);
          _scheduleCorrection(rowKey, index: index, itemCount: itemCount);
        case AnimationStatus.dismissed:
          // 弹层被关掉（入场动画倒放）：不再校正，撤监听。
          entrance.removeStatusListener(listener);
        default:
          break;
      }
    }
    entrance.addStatusListener(listener);
  }

  void _scheduleCorrection(GlobalKey rowKey, {required int index, required int itemCount}) {
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _centerOn(rowKey, index: index, itemCount: itemCount, animate: false),
    );
  }

  /// 头部定位按钮：瞬移到目标行邻域，挂载后平滑精修居中。
  Future<void> locate(int index, GlobalKey rowKey, {required int itemCount}) =>
      _centerOn(rowKey, index: index, itemCount: itemCount, animate: true);

  /// 两段式居中：实测步长估算 jump（未挂载则重估重跳）→ ensureVisible 精修。
  ///
  /// 目标行始终未挂载/无 client 时停留在最后一次估算位返回，不崩溃。
  Future<void> _centerOn(
    GlobalKey rowKey, {
    required int index,
    required int itemCount,
    required bool animate,
  }) async {
    if (!controller.hasClients) return;
    // 第一段：按实测步长 jump 到居中估算位。懒列表挂载目标行需要一帧，
    // 仍未挂载说明估算偏了（字体缩放等）——重挂载后 extent 更准，重估
    // 重跳（行均匀缩放一轮即收敛；上限 3 轮防极端不收敛死循环）。
    BuildContext? rowContext;
    for (var round = 0; round < _maxJumpRounds; round++) {
      controller.jumpTo(_centerEstimate(index, _measuredStride(itemCount)));
      // 主动排帧并等帧结束：懒列表围绕新偏移重建后才能查挂载。
      WidgetsBinding.instance.scheduleFrame();
      await WidgetsBinding.instance.endOfFrame;
      if (!controller.hasClients) return;
      rowContext = rowKey.currentContext;
      if (rowContext != null && rowContext.mounted) break;
      rowContext = null;
    }
    if (rowContext == null || !rowContext.mounted) return;
    // 第二段：精修到几何精确居中。
    await Scrollable.ensureVisible(
      rowContext,
      alignment: 0.5,
      duration: animate ? const Duration(milliseconds: 250) : Duration.zero,
      curve: Curves.easeOutCubic,
    );
  }

  /// 目标行居中偏移估算：按给定步长与真实视口，clamp 到合法滚动范围。
  double _centerEstimate(int index, double stride) {
    final position = controller.position;
    return ((index + 0.5) * stride - position.viewportDimension / 2)
        .clamp(0.0, position.maxScrollExtent);
  }

  /// 实测行步长：懒构建 sliver 的 scrollExtent 含未构建项的估计，
  /// (maxScrollExtent + viewportDimension) ≈ 内容总长，除以行数即平均
  /// 步长——字体缩放下行高增大也能跟上（终审探针已验证收敛）。
  /// 行数非正或 extent 未就绪时回退构造期标称步长。
  double _measuredStride(int itemCount) {
    if (itemCount <= 0) return _rowStride;
    final position = controller.position;
    final extent = position.maxScrollExtent + position.viewportDimension;
    if (extent <= 0) return _rowStride;
    return extent / itemCount;
  }

  void dispose() => controller.dispose();
}
