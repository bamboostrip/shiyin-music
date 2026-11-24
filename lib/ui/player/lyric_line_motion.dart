import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../models/lyric_motion_style.dart';

/// 歌词行动效包装（issue #26）。
///
/// 标准样式直接返回 [child]，不额外建图层，渲染路径与改造前完全一致。
///
/// 灵动样式（Apple Music 风）：
/// - 当前行（[active]）弹性放大：easeOutBack 的过冲就是「回弹」，失活时
///   收回；缩放走 Transform，不改字号，行高与滚动定位的估算偏移都不受影响；
/// - 非当前行按与当前行的距离贴一层轻微高斯模糊（[blurSigmaFor]）；超出
///   [maxBlurDistance] 的行不再模糊，只靠原有透明度渐隐——每行一个
///   saveLayer，模糊行必须限量，否则低端机滚动时会掉帧；
/// - 视线聚焦行（用户手动滚动时的准星行）传入 [distance] = 0 即可保持清晰。
class LyricLineMotion extends StatelessWidget {
  const LyricLineMotion({
    super.key,
    required this.style,
    required this.active,
    required this.distance,
    required this.child,
    this.alignment = Alignment.centerLeft,
  });

  final LyricMotionStyle style;
  final bool active;

  /// 与当前播放行的行距（0 = 当前行/聚焦行）。只用于决定模糊强度。
  final int distance;
  final Widget child;

  /// 缩放锚点：左中对齐，放大时文字不会左右横移。
  final Alignment alignment;

  /// 最多模糊到距当前行 3 行：更远的行已经淡到看不清，不值得再开图层。
  static const int maxBlurDistance = 3;

  /// 当前行放大 4.5%：叠加字号 20→26 的既有变化后，视觉上明显大于标准样式。
  static const double activeScaleDelta = 0.045;

  /// 距离 → 模糊强度。0 表示清晰（当前行或手动滚动时的准星行）。
  static double blurSigmaFor(int distance) {
    return switch (distance) {
      <= 0 => 0,
      1 => 1.15,
      2 => 1.45,
      _ => 1.7,
    };
  }

  @override
  Widget build(BuildContext context) {
    if (style != LyricMotionStyle.lively) return child;

    final target = active ? 1.0 : 0.0;
    final baseBlur = distance > maxBlurDistance ? 0.0 : blurSigmaFor(distance);
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: target),
      duration: active
          ? const Duration(milliseconds: 420)
          : const Duration(milliseconds: 240),
      curve: active ? Curves.easeOutBack : Curves.easeOutCubic,
      child: child,
      builder: (context, t, child) {
        var result = child!;
        if (baseBlur > 0) {
          // 进入当前行时（distance 变 0）直接清晰；退出当前行时
          // （t 1→0）模糊从 0 平滑加重。
          final sigma = baseBlur * (1 - t.clamp(0.0, 1.0));
          if (sigma > 0.01) {
            result = ImageFiltered(
              imageFilter: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
              child: result,
            );
          }
        }
        final scale = 1 + activeScaleDelta * t;
        if (scale > 1.001) {
          result = Transform.scale(
            scale: scale,
            alignment: alignment,
            child: result,
          );
        }
        return result;
      },
    );
  }
}
