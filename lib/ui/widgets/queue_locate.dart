// lib/ui/widgets/queue_locate.dart
import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 播放队列面板「定位到正在播放行」的滚动控制（issue #28）。
///
/// 职责纯滚动，不感知 PlayerController：
/// - 构造时按固定行步长估算 [controller] 的初始偏移（假定视口 480 居中，
///   只求首帧落点接近，误差由校正兜底）；
/// - 队列面板在带入场动画的 modal 底部弹层里，动画期间视口高度在变，
///   [correctWhenEntranceSettled] 等路由动画播完后的下一帧再
///   `ensureVisible` 居中（无动画/已播完则下一帧立即校正）；
/// - [locate] 供头部定位按钮平滑滚回（~250ms）。
///
/// 队列面板均为 shrinkWrap 全量构建，目标行 context 必在，无需懒加载探测。
class QueueLocateController {
  QueueLocateController({
    required double rowStride,
    int? initialIndex,
    double assumedViewportExtent = 480,
  })  : controller = ScrollController(
          // 目标行中心对准假定视口中心；480 为手机弹层内容区典型高度，
          // 偏差只影响入场结束后的校正跳变量（≤ 半个视口误差的一半）。
          initialScrollOffset: initialIndex == null || initialIndex < 0
              ? 0
              : math.max(0.0, (initialIndex + 0.5) * rowStride - assumedViewportExtent / 2),
        );

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
    WidgetsBinding.instance.addPostFrameCallback((_) => _centerOn(rowKey, animate: false));
  }

  /// 头部定位按钮：平滑滚回目标行居中。
  Future<void> locate(GlobalKey rowKey) async {
    await _centerOn(rowKey, animate: true);
  }

  Future<void> _centerOn(GlobalKey rowKey, {required bool animate}) async {
    if (!controller.hasClients) return;
    final rowContext = rowKey.currentContext;
    if (rowContext == null) return;
    await Scrollable.ensureVisible(
      rowContext,
      alignment: 0.5,
      duration: animate ? const Duration(milliseconds: 250) : Duration.zero,
      curve: Curves.easeOutCubic,
    );
  }

  void dispose() => controller.dispose();
}
