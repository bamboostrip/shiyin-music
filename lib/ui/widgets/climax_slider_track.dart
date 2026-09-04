import 'package:flutter/material.dart';

import '../../models/music_models.dart';

/// 高潮起始位置映射为 0..1，轨道内画标记用；无效时返回 null（不画标记）。
double? climaxStartFraction({
  required SongClimax? climax,
  required int durationMs,
}) {
  if (climax == null || !climax.isValid || durationMs <= 0) return null;
  final start = (climax.startTime.inMilliseconds / durationMs).clamp(0.0, 1.0);
  if (start <= 0 || start >= 1.0) return null;
  return start;
}

/// 进度条轨道：在轨道内部标记高潮起始位置（替代原先轨道下方的圆点）。
///
/// 绘制顺序：整条未播放底轨 -> 高潮起点小标记 -> 已播放进度（系统默认
/// 加高 2px，播放头经过后盖住标记）。thumb 位置由 Slider 框架按全宽线性
/// 映射传入，标记同样按全宽线性映射定位（fraction 与 Slider value 同系）。
/// 播放页与桌面底部播放栏共用。
class ClimaxSliderTrackShape extends RoundedRectSliderTrackShape {
  const ClimaxSliderTrackShape({
    required this.climaxStart,
    required this.markerColor,
  });

  final double? climaxStart;
  final Color markerColor;

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required TextDirection textDirection,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isDiscrete = false,
    bool isEnabled = false,
    double additionalActiveTrackHeight = 2,
  }) {
    if (sliderTheme.trackHeight == null || sliderTheme.trackHeight! <= 0) {
      return;
    }

    final canvas = context.canvas;
    final trackRect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    final trackRadius = Radius.circular(trackRect.height / 2);
    final activePaint = Paint()
      ..color = ColorTween(
        begin: sliderTheme.disabledActiveTrackColor,
        end: sliderTheme.activeTrackColor,
      ).evaluate(enableAnimation)!;
    final inactivePaint = Paint()
      ..color = ColorTween(
        begin: sliderTheme.disabledInactiveTrackColor,
        end: sliderTheme.inactiveTrackColor,
      ).evaluate(enableAnimation)!;

    // 1. 整条未播放底轨。
    canvas.drawRRect(
      RRect.fromRectAndRadius(trackRect, trackRadius),
      inactivePaint,
    );

    // 2. 高潮起点标记：沿用高潮段的高亮色，只取起点处一小段，
    //    高度与轨道完全齐平（不超出进度条），水平方向夹在轨道范围内。
    final start = climaxStart;
    if (start != null) {
      final markerWidth = (trackRect.height * 1.6).clamp(6.0, 9.0);
      final centerDx = (trackRect.left + start * trackRect.width).clamp(
        trackRect.left + markerWidth / 2,
        trackRect.right - markerWidth / 2,
      );
      final markerRect = Rect.fromCenter(
        center: Offset(centerDx, trackRect.center.dy),
        width: markerWidth,
        height: trackRect.height,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(markerRect, trackRadius),
        Paint()..color = markerColor,
      );
    }

    // 3. 已播放进度（与系统默认一致，加高 2px；播放头经过后覆盖标记）。
    if (thumbCenter.dx > trackRect.left) {
      final activeRect = Rect.fromLTRB(
        trackRect.left,
        trackRect.top - additionalActiveTrackHeight / 2,
        thumbCenter.dx,
        trackRect.bottom + additionalActiveTrackHeight / 2,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          activeRect,
          Radius.circular((trackRect.height + additionalActiveTrackHeight) / 2),
        ),
        activePaint,
      );
    }
  }
}
