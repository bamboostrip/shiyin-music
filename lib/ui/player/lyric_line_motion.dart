import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../models/lyric_motion_style.dart';

/// 行级歌词包装：只处理**景深**样式；标准直接透传，灵动由整页
/// Apple 歌词组件（[ShiyinAppleLyrics]）接管，不经过这里。
///
/// 景深样式复刻参考实现 `BlurredLyricView` 的参数：
/// sigma = min(3.0, 0.7 × 行距)，不做 ±3 行截断（越远越模糊，封顶 3.0），
/// 没有弹性放大；行距变化时 sigma 直接切换、不做过渡动画（参考实现按行
/// 即时算 sigma；过渡会让每句多行一起重建模糊图层）。
///
/// 视线聚焦行（用户手动滚动时的准星行）传入 [distance] = 0 即可保持清晰。
class LyricLineMotion extends StatelessWidget {
  const LyricLineMotion({
    super.key,
    required this.style,
    required this.distance,
    required this.child,
  });

  final LyricMotionStyle style;

  /// 与当前播放行的行距（0 = 当前行/聚焦行）。只用于决定模糊强度。
  final int distance;
  final Widget child;

  /// 景深样式参数（对齐参考实现 `_lyricBlurSigma/_lyricBlurStep`）。
  static const double depthMaxBlurSigma = 3.0;
  static const double depthBlurStep = 0.7;

  /// 距离 → 模糊强度。0 表示清晰（当前行/准星行）。
  static double blurSigmaFor(int distance) {
    if (distance <= 0) return 0;
    return math
        .min(depthMaxBlurSigma, depthBlurStep * distance)
        .toDouble();
  }

  @override
  Widget build(BuildContext context) {
    if (style != LyricMotionStyle.depth) return child;

    final sigma = blurSigmaFor(distance);
    if (sigma <= 0.01) return child;
    return ImageFiltered(
      imageFilter: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
      child: child,
    );
  }
}
