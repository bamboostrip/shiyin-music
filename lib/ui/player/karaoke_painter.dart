import 'package:flutter/material.dart';

import '../../models/music_models.dart';

class KaraokeLinePainter extends CustomPainter {
  KaraokeLinePainter({
    required this.line,
    required this.position,
    required this.style,
    required this.baseColor,
    required this.activeColor,
    required this.textDirection,
    required this.textAlign,
    required this.maxLines,
    required this.maxWidth,
  }) {
    _textPainter = TextPainter(
      text: TextSpan(
        text: line.text,
        style: style.copyWith(color: baseColor),
      ),
      textDirection: textDirection,
      textAlign: textAlign,
      maxLines: maxLines,
    )..layout(maxWidth: maxLines == 1 ? double.infinity : maxWidth);
  }

  final LyricLine line;
  final Duration position;
  final TextStyle style;
  final Color baseColor;
  final Color activeColor;
  final TextDirection textDirection;
  final TextAlign textAlign;
  final int? maxLines;
  final double maxWidth;
  late final TextPainter _textPainter;

  double get width => _textPainter.width;
  double get height => _textPainter.height;

  @override
  void paint(Canvas canvas, Size size) {
    _textPainter.paint(canvas, Offset.zero);

    var start = 0;
    for (final word in line.words) {
      final end = start + word.text.length;
      final progress = _wordProgress(word);
      if (progress > 0) {
        _paintWordProgress(canvas, start, end, progress);
      }
      start = end;
    }
  }

  double _wordProgress(LyricWord word) {
    if (position < word.time) return 0;
    final durationMs = word.duration.inMilliseconds;
    if (durationMs <= 0) return 1;
    final elapsed = position.inMilliseconds - word.time.inMilliseconds;
    return (elapsed / durationMs).clamp(0, 1).toDouble();
  }

  void _paintWordProgress(Canvas canvas, int start, int end, double progress) {
    final selection = TextSelection(baseOffset: start, extentOffset: end);
    final boxes = _textPainter.getBoxesForSelection(selection);
    if (boxes.isEmpty) return;

    final highlightPainter = TextPainter(
      text: TextSpan(
        text: line.text,
        style: style.copyWith(color: activeColor),
      ),
      textDirection: textDirection,
      textAlign: textAlign,
      maxLines: maxLines,
    )..layout(maxWidth: maxLines == 1 ? double.infinity : maxWidth);

    for (final box in boxes) {
      final rect = box.toRect();
      final clipWidth = rect.width * progress.clamp(0, 1);
      if (clipWidth <= 0) continue;

      canvas.save();
      canvas.clipRect(
        Rect.fromLTWH(rect.left, rect.top, clipWidth, rect.height),
      );
      highlightPainter.paint(canvas, Offset.zero);
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant KaraokeLinePainter oldDelegate) {
    return oldDelegate.position != position ||
        oldDelegate.line != line ||
        oldDelegate.style != style ||
        oldDelegate.maxWidth != maxWidth;
  }
}
