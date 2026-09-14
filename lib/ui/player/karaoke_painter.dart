import 'package:flutter/material.dart';

import '../../models/music_models.dart';

/// 逐字卡拉OK着色 painter：底层整行 base 色，上层按每个字的播放进度
/// 裁剪绘制高亮层。
///
/// 生命周期契约：本 Flutter 版本的 [CustomPainter] 没有 dispose 钩子，
/// 框架不会回收 painter 持有的 TextPainter 原生排版资源——必须由持有方
/// （LyricText 的 State）在替换/销毁时显式调用 [release]。播放位置变化
/// 走 [withPosition] 生成共享排版结果的轻量副本，避免每帧两次完整
/// layout（海报页播放中每帧都在重建）。
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
  }) : _ownsPainters = true {
    _textPainter = TextPainter(
      text: TextSpan(
        text: line.text,
        style: style.copyWith(color: baseColor),
      ),
      textDirection: textDirection,
      textAlign: textAlign,
      maxLines: maxLines,
    )..layout(maxWidth: maxLines == 1 ? double.infinity : maxWidth);
    // 高亮 painter 必须与主 painter 共享同一份排版参数（仅颜色不同），
    // 否则逐字裁剪矩形会与高亮文字错位。paint() 只做裁剪与复绘。
    _highlightPainter = TextPainter(
      text: TextSpan(
        text: line.text,
        style: style.copyWith(color: activeColor),
      ),
      textDirection: textDirection,
      textAlign: textAlign,
      maxLines: maxLines,
    )..layout(maxWidth: maxLines == 1 ? double.infinity : maxWidth);
  }

  KaraokeLinePainter._reuse({
    required this.line,
    required this.position,
    required this.style,
    required this.baseColor,
    required this.activeColor,
    required this.textDirection,
    required this.textAlign,
    required this.maxLines,
    required this.maxWidth,
    required TextPainter textPainter,
    required TextPainter highlightPainter,
  }) : _textPainter = textPainter,
       _highlightPainter = highlightPainter,
       _ownsPainters = true;

  final LyricLine line;
  Duration position;
  final TextStyle style;
  final Color baseColor;
  final Color activeColor;
  final TextDirection textDirection;
  final TextAlign textAlign;
  final int? maxLines;
  final double maxWidth;
  late final TextPainter _textPainter;
  late final TextPainter _highlightPainter;
  bool _ownsPainters;

  double get width => _textPainter.width;
  double get height => _textPainter.height;

  /// 用新的播放位置生成共享排版结果的副本：不重新 layout，直接复用
  /// 本实例的两个 TextPainter。调用后本实例放弃所有权（不再可释放），
  /// 由副本负责最终释放。
  KaraokeLinePainter withPosition(Duration newPosition) {
    _ownsPainters = false;
    return KaraokeLinePainter._reuse(
      line: line,
      position: newPosition,
      style: style,
      baseColor: baseColor,
      activeColor: activeColor,
      textDirection: textDirection,
      textAlign: textAlign,
      maxLines: maxLines,
      maxWidth: maxWidth,
      textPainter: _textPainter,
      highlightPainter: _highlightPainter,
    );
  }

  /// 释放原生排版资源（框架无 dispose 钩子，必须由持有方显式调用）。
  /// 已让渡所有权（withPosition 之后）的实例调用是安全的空操作。
  void release() {
    if (!_ownsPainters) return;
    _ownsPainters = false;
    _textPainter.dispose();
    _highlightPainter.dispose();
  }

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

    for (final box in boxes) {
      final rect = box.toRect();
      final clipWidth = rect.width * progress.clamp(0, 1);
      if (clipWidth <= 0) continue;

      canvas.save();
      canvas.clipRect(
        Rect.fromLTWH(rect.left, rect.top, clipWidth, rect.height),
      );
      _highlightPainter.paint(canvas, Offset.zero);
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
