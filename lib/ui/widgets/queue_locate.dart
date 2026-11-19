// lib/ui/widgets/queue_locate.dart
import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 播放队列面板「定位到正在播放行」的滚动控制（issue #28）。
///
/// 职责纯滚动，不感知 PlayerController：
/// - 构造时按固定行步长估算 [controller] 的初始偏移（假定视口 480 居中，
///   只求首帧落点接近，误差由校正兜底）；
/// - 队列面板在带入场动画的 modal 底部弹层里，动画期间视口高度在变，
///   [correctWhenEntranceSettled] 等路由动画播完后再校正（无动画/已播完
///   则下一帧立即）：两段式——先按真实视口 jump 到居中估算位（不依赖
///   目标行是否挂载），再下一帧 `ensureVisible` 精修居中；
/// - [locate] 供头部定位按钮：同样两段式，先瞬移到目标邻域（长队列不
///   做跨几百行的长滚动动画），行挂载后 ~250ms 平滑精修。
///
/// 列表是懒构建的：目标行滚出视口 + 缓存区后 context 即被卸载，
/// 两段式的第一段（按步长估算 jump）保证无论挂载与否都能落到位。
class QueueLocateController {
  QueueLocateController({
    required double rowStride,
    int? initialIndex,
    double assumedViewportExtent = 480,
  })  : _rowStride = rowStride,
        _initialIndex = initialIndex,
        _assumedViewportExtent = assumedViewportExtent,
        controller = ScrollController(
          // 目标行中心对准假定视口中心；480 为手机弹层内容区典型高度，
          // 偏差只影响入场结束后的校正跳变量（≤ 半个视口误差的一半）。
          initialScrollOffset: initialIndex == null || initialIndex < 0
              ? 0
              : math.max(0.0, (initialIndex + 0.5) * rowStride - assumedViewportExtent / 2),
        );

  final double _rowStride;
  final int? _initialIndex;
  final double _assumedViewportExtent;
  final ScrollController controller;

  /// 精确校正：目标行 [rowKey] 居中。宿主在首帧后的回调里调用。
  void correctWhenEntranceSettled(Animation<double>? entrance, GlobalKey rowKey) {
    if (entrance == null || entrance.isCompleted) {
      _scheduleCorrection(rowKey);
      return;
    }
    void listener(AnimationStatus status) {
      switch (status) {
        case AnimationStatus.completed:
          entrance.removeStatusListener(listener);
          _scheduleCorrection(rowKey);
        case AnimationStatus.dismissed:
          // 弹层被关掉（入场动画倒放）：不再校正，撤监听。
          entrance.removeStatusListener(listener);
        default:
          break;
      }
    }
    entrance.addStatusListener(listener);
  }

  void _scheduleCorrection(GlobalKey rowKey) {
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _centerOn(_initialIndex ?? 0, rowKey, animate: false),
    );
  }

  /// 头部定位按钮：瞬移到目标行邻域，挂载后平滑精修居中。
  Future<void> locate(int index, GlobalKey rowKey) =>
      _centerOn(index, rowKey, animate: true);

  /// 两段式居中：jump 估算 → 等一帧（懒列表围绕新偏移重建）→ 精修。
  ///
  /// 目标行未挂载/无 client 时停留在估算位返回，不崩溃。
  Future<void> _centerOn(int index, GlobalKey rowKey, {required bool animate}) async {
    if (!controller.hasClients) return;
    // 第一段：按真实视口估算居中偏移，瞬移过去（无需目标行挂载）。
    controller.jumpTo(_centerEstimate(index));
    // 第二段：主动排帧并等帧结束，让懒列表先挂载目标行再精修。
    WidgetsBinding.instance.scheduleFrame();
    await WidgetsBinding.instance.endOfFrame;
    if (!controller.hasClients) return;
    final rowContext = rowKey.currentContext;
    if (rowContext == null || !rowContext.mounted) return;
    await Scrollable.ensureVisible(
      rowContext,
      alignment: 0.5,
      duration: animate ? const Duration(milliseconds: 250) : Duration.zero,
      curve: Curves.easeOutCubic,
    );
  }

  /// 目标行居中偏移估算：优先用真实视口，无 client 时退回构造期假定视口。
  double _centerEstimate(int index) {
    if (controller.hasClients) {
      final position = controller.position;
      return ((index + 0.5) * _rowStride - position.viewportDimension / 2)
          .clamp(0.0, position.maxScrollExtent);
    }
    return math.max(0.0, (index + 0.5) * _rowStride - _assumedViewportExtent / 2);
  }

  void dispose() => controller.dispose();
}
