import 'package:flutter/material.dart';

/// Calculates marquee scroll offset for long lyrics.
///
/// When [textWidth] <= [availableWidth], returns `0.0`.
/// When [textWidth] > [availableWidth], max scroll is `textWidth - availableWidth + 32.0`,
/// and returned offset is `-maxScroll * progress.clamp(0.0, 1.0)`.
double calculateMarqueeOffset({
  required double textWidth,
  required double availableWidth,
  required double progress,
}) {
  return LyricsKaraokeLine.calculateMarqueeOffset(
    textWidth: textWidth,
    availableWidth: availableWidth,
    progress: progress,
  );
}

/// Custom clipper for progressive karaoke highlight coloring.
class ProgressClipper extends CustomClipper<Rect> {
  const ProgressClipper({
    required this.progress,
    required this.textWidth,
  });

  final double progress;
  final double textWidth;

  @override
  Rect getClip(Size size) {
    final clipWidth =
        (textWidth * progress.clamp(0.0, 1.0)).clamp(0.0, double.infinity);
    return Rect.fromLTWH(0, -20.0, clipWidth, size.height + 40.0);
  }

  @override
  bool shouldReclip(covariant ProgressClipper oldClipper) {
    return oldClipper.progress != progress || oldClipper.textWidth != textWidth;
  }
}

/// Alias for internal progress clipper.
typedef _ProgressClipper = ProgressClipper;

/// 逐字变色歌词行渲染器与长歌词跑马灯平滑滚动组件。
///
/// 采用双层叠放架构 (Base unplayed layer + Top played highlight layer) 与
/// [ProgressClipper] 实现逐字/平滑变色渲染；
/// 当单行文本宽度超出 [availableWidth] 时，自动开启平滑跑马灯位移。
class LyricsKaraokeLine extends StatefulWidget {
  const LyricsKaraokeLine({
    super.key,
    required this.text,
    required this.fontSize,
    required this.playedColor,
    required this.unplayedColor,
    required this.progress,
    required this.availableWidth,
    this.alignment = TextAlign.center,
    this.textOpacity = 1.0,
    this.fontWeight = FontWeight.bold,
  });

  final String text;
  final double fontSize;
  final Color playedColor;
  final Color unplayedColor;
  final double progress;
  final double availableWidth;
  final TextAlign alignment;
  final double textOpacity;
  final FontWeight fontWeight;

  /// 计算跑马灯平移量（负值向左平移）。
  static double calculateMarqueeOffset({
    required double textWidth,
    required double availableWidth,
    required double progress,
  }) {
    if (textWidth <= availableWidth) {
      return 0.0;
    }
    final maxScroll = textWidth - availableWidth + 32.0;
    final clampedProgress = progress.clamp(0.0, 1.0);
    return -maxScroll * clampedProgress;
  }

  @override
  State<LyricsKaraokeLine> createState() => _LyricsKaraokeLineState();
}

class _LyricsKaraokeLineState extends State<LyricsKaraokeLine> {
  late TextPainter _textPainter;
  double _textWidth = 0.0;

  /// 内部 TextPainter 必须与两个渲染 Text 应用同一系统文本缩放：
  /// 缺失时（历史实现）测量宽度 < 实际绘制宽度，逐字高亮的 clip 边界
  /// 滞后、跑马灯溢出判定失真（Windows 辅助功能文本缩放 ≠ 100% 时）。
  TextScaler _textScaler = TextScaler.noScaling;

  @override
  void initState() {
    super.initState();
    _initTextPainter();
  }

  void _initTextPainter() {
    _textPainter = TextPainter(
      text: TextSpan(
        text: widget.text,
        style: TextStyle(
          decoration: TextDecoration.none,
          fontSize: widget.fontSize,
          fontWeight: widget.fontWeight,
        ),
      ),
      textDirection: TextDirection.ltr,
      textScaler: _textScaler,
      maxLines: 1,
    )..layout();
    _textWidth = _textPainter.width;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scaler = MediaQuery.textScalerOf(context);
    if (scaler != _textScaler) {
      _textScaler = scaler;
      _textPainter.dispose();
      _initTextPainter();
    }
  }

  @override
  void didUpdateWidget(covariant LyricsKaraokeLine oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.text != oldWidget.text ||
        widget.fontSize != oldWidget.fontSize ||
        widget.fontWeight != oldWidget.fontWeight) {
      _textPainter.dispose();
      _initTextPainter();
    }
  }

  @override
  void dispose() {
    _textPainter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final safeOpacity = widget.textOpacity.clamp(0.0, 1.0);

    final textWidth = _textWidth;
    final isOverflow = textWidth > widget.availableWidth;

    // 可读性方案对齐 QQ 音乐桌面歌词：不用重阴影（浅色桌面上发闷），
    // 而是「同色系深色细描边 + 单层轻投影」——描边保证字形边缘在任何
    // 底色上都锐利，轻投影只做分离度兜底。
    final baseShadow = Shadow(
      color: Colors.black.withValues(alpha: 0.30 * safeOpacity),
      blurRadius: 4,
      offset: const Offset(0, 1.5),
    );
    // 描边宽度随字号缩放，钳制在细线范围。
    final strokeWidth = (widget.fontSize * 0.075).clamp(1.4, 3.2);

    Paint outlinePaintFor(Color color) {
      final hsl = HSLColor.fromColor(color);
      // 同色系深色：降亮度得到描边色，alpha 跟随本层文字。
      final outline = hsl
          .withLightness((hsl.lightness * 0.42).clamp(0.0, 1.0))
          .toColor()
          .withValues(alpha: color.a);
      return Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeJoin = StrokeJoin.round
        ..color = outline;
    }

    Widget lyricLayer(Color color) {
      final baseStyle = TextStyle(
        decoration: TextDecoration.none,
        fontSize: widget.fontSize,
        fontWeight: widget.fontWeight,
      );
      return Stack(
        fit: StackFit.passthrough,
        children: [
          // 描边层（附轻投影）
          Text(
            widget.text,
            maxLines: 1,
            softWrap: false,
            style: baseStyle.copyWith(
              foreground: outlinePaintFor(color),
              shadows: [baseShadow],
            ),
          ),
          // 填充层
          Text(
            widget.text,
            maxLines: 1,
            softWrap: false,
            style: baseStyle.copyWith(color: color),
          ),
        ],
      );
    }

    final karaokeStack = Stack(
      fit: StackFit.loose,
      children: [
        // Base Layer (unplayed)
        // 传入颜色自身的 alpha 参与合成（相乘而非覆盖）：
        // 双行模式靠它区分当前句与下一句（1.0 vs 0.85）。
        lyricLayer(
          widget.unplayedColor.withValues(
            alpha: widget.unplayedColor.a * safeOpacity,
          ),
        ),
        // Top Highlight Layer (played)
        ClipRect(
          clipper: _ProgressClipper(
            progress: widget.progress.clamp(0.0, 1.0),
            textWidth: textWidth,
          ),
          child: lyricLayer(
            widget.playedColor.withValues(
              alpha: widget.playedColor.a * safeOpacity,
            ),
          ),
        ),
      ],
    );

    if (isOverflow) {
      final scrollOffset = LyricsKaraokeLine.calculateMarqueeOffset(
        textWidth: textWidth,
        availableWidth: widget.availableWidth,
        progress: widget.progress,
      );

      // 显式测量高度：外层常是 FittedBox(scaleDown)（给子级无界高度约束），
      // OverflowBox 只约束宽度时会把自身高度解析成 Infinity 直接布局断言
      // （悬浮窗/设置预览中超长歌词行 + 文本缩放 ≠100% 必触发）。
      return SizedBox(
        width: widget.availableWidth,
        height: _textPainter.height,
        child: ClipRect(
          child: Transform.translate(
            offset: Offset(scrollOffset, 0),
            child: OverflowBox(
              alignment: Alignment.centerLeft,
              minWidth: 0,
              maxWidth: double.infinity,
              child: karaokeStack,
            ),
          ),
        ),
      );
    } else {
      final Alignment childAlignment = switch (widget.alignment) {
        TextAlign.left || TextAlign.start => Alignment.centerLeft,
        TextAlign.right || TextAlign.end => Alignment.centerRight,
        TextAlign.center || TextAlign.justify => Alignment.center,
      };

      return SizedBox(
        width: widget.availableWidth,
        child: Align(
          alignment: childAlignment,
          child: karaokeStack,
        ),
      );
    }
  }
}
