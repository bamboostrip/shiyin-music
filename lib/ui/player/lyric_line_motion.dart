import 'dart:math' as math;
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
/// - 模糊带内强度恒定（不做「越远越模糊」）：行距每推进一行都会重建图层，
///   恒强可让每句只动边界那 1~2 行；强度本身也做隐式动画，行距跨过上限
///   （以及当前行进出模糊带）时是渐变而不是瞬间跳变，否则播放推进到边界
///   那一句时会看到远处某行「突然变清晰」；
/// - 视线聚焦行（用户手动滚动时的准星行）传入 [distance] = 0 即可保持清晰。
///
/// 上游景深样式：
/// - 直接复刻上游 `BlurredLyricView` 的参数：sigma = min(3.0, 0.7 × 行距)，
///   不做 ±3 行截断（越远越模糊，封顶 3.0）；
/// - 没有弹性放大（上游只靠 active/inactive 字号与高亮区分）；
/// - 与上游一致，行距变化时 sigma 直接切换、不做过渡动画：上游是按行即时
///   换 sigma，且过渡会让每句最多 8 行同时重建 240ms 的模糊图层。
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

  /// 灵动样式最多模糊到距当前行 3 行：更远的行已经淡到看不清，不值得再开图层。
  static const int maxBlurDistance = 3;

  /// 灵动样式当前行放大 4.5%：叠加字号 20→26 的既有变化后，视觉上明显大于标准样式。
  static const double activeScaleDelta = 0.045;

  /// 灵动样式模糊强度切换的隐式动画时长：与失活缩放同档，短到不拖沓。
  static const Duration blurTransitionDuration = Duration(milliseconds: 240);

  /// 灵动样式模糊带内的统一强度。
  ///
  /// 不随行距递增：行距每推进一行，那一行的 sigma 变化都会触发隐式动画，
  /// 递增会让每句都有 6 行一起重建图层；恒定则每句只动跨过边界的那 1~2 行。
  static const double blurSigma = 1.4;

  /// 上游景深样式参数（对齐上游 `player_page.dart` 的 `_lyricBlurSigma/_lyricBlurStep`）。
  static const double upstreamMaxBlurSigma = 3.0;
  static const double upstreamBlurStep = 0.7;

  /// 距离 → 模糊强度。0 表示清晰（当前行/准星行，或该样式不模糊）。
  static double blurSigmaFor(LyricMotionStyle style, int distance) {
    if (distance <= 0) return 0;
    return switch (style) {
      LyricMotionStyle.standard => 0,
      LyricMotionStyle.lively => distance > maxBlurDistance
          ? 0
          : blurSigma,
      LyricMotionStyle.upstream => math
          .min(upstreamMaxBlurSigma, upstreamBlurStep * distance)
          .toDouble(),
    };
  }

  /// 该样式是否给当前行做弹性放大（上游没有缩放，只靠字号/高亮区分）。
  static bool scalesActiveLine(LyricMotionStyle style) {
    return style == LyricMotionStyle.lively;
  }

  @override
  Widget build(BuildContext context) {
    if (style == LyricMotionStyle.standard) return child;

    final baseBlur = blurSigmaFor(style, distance);
    if (style == LyricMotionStyle.upstream) {
      // 与上游一致：按行即时切换 sigma，不做过渡动画（上游 BlurredLyricView
      // 也是每行直接算 min(3.0, 0.7×距离)）。这样每句只重建一次图层，避免
      // 距离变化的 8 行一起跑 240ms 的模糊动画。
      if (baseBlur <= 0.01) return child;
      return ImageFiltered(
        imageFilter: ui.ImageFilter.blur(sigmaX: baseBlur, sigmaY: baseBlur),
        child: child,
      );
    }

    // 灵动样式：外层动画只负责模糊目标值，跨过模糊上限 / 进出当前行时
    // sigma 从旧值渐变到新值，而不是在重建这一帧直接跳变。
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: baseBlur),
      duration: blurTransitionDuration,
      curve: Curves.easeOutCubic,
      child: child,
      builder: (context, blur, child) {
        var result = child!;
        if (blur > 0.01) {
          result = ImageFiltered(
            imageFilter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
            child: result,
          );
        }
        if (!scalesActiveLine(style)) return result;
        return _ActiveScale(
          active: active,
          alignment: alignment,
          child: result,
        );
      },
    );
  }
}

/// 当前行弹性缩放（独立一层隐式动画，避免与模糊强度互相干扰）。
class _ActiveScale extends StatelessWidget {
  const _ActiveScale({
    required this.active,
    required this.alignment,
    required this.child,
  });

  final bool active;
  final Alignment alignment;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: active ? 1.0 : 0.0),
      duration: active
          ? const Duration(milliseconds: 420)
          : const Duration(milliseconds: 240),
      curve: active ? Curves.easeOutBack : Curves.easeOutCubic,
      child: child,
      builder: (context, t, child) {
        final scale = 1 + LyricLineMotion.activeScaleDelta * t;
        if (scale <= 1.001) return child!;
        return Transform.scale(
          scale: scale,
          alignment: alignment,
          child: child,
        );
      },
    );
  }
}
