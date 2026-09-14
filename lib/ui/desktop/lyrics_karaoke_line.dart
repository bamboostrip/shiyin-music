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

    final unplayedShadows = [
      Shadow(
        color: Colors.black.withValues(alpha: (0.75 * safeOpacity).clamp(0.0, 1.0)),
        blurRadius: 6,
        offset: const Offset(0, 1),
      ),
      Shadow(
        color: Colors.black.withValues(alpha: (0.45 * safeOpacity).clamp(0.0, 1.0)),
        blurRadius: 14,
      ),
    ];

    final playedShadows = [
      Shadow(
        color: Colors.black.withValues(alpha: (0.85 * safeOpacity).clamp(0.0, 1.0)),
        blurRadius: 6,
        offset: const Offset(0, 1),
      ),
      Shadow(
        color: widget.playedColor.withValues(alpha: (0.40 * safeOpacity).clamp(0.0, 1.0)),
        blurRadius: 12,
      ),
    ];

    final textStyle = TextStyle(
      decoration: TextDecoration.none,
      fontSize: widget.fontSize,
      fontWeight: widget.fontWeight,
    );

    final textWidth = _textWidth;
    final isOverflow = textWidth > widget.availableWidth;

    final karaokeStack = Stack(
      fit: StackFit.loose,
      children: [
        // Base Layer (unplayed)
        Text(
          widget.text,
          maxLines: 1,
          softWrap: false,
          style: textStyle.copyWith(
            color: widget.unplayedColor.withValues(alpha: safeOpacity),
            shadows: unplayedShadows,
          ),
        ),
        // Top Highlight Layer (played)
        ClipRect(
          clipper: _ProgressClipper(
            progress: widget.progress.clamp(0.0, 1.0),
            textWidth: textWidth,
          ),
          child: Text(
            widget.text,
            maxLines: 1,
            softWrap: false,
            style: textStyle.copyWith(
              color: widget.playedColor.withValues(alpha: safeOpacity),
              shadows: playedShadows,
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
