import 'package:flutter/material.dart';

import '../../models/music_models.dart';
import 'karaoke_painter.dart';

/// 逐字卡拉OK歌词行（有 word 级时间且为当前行时启用 [KaraokeLinePainter]）。
///
/// 有状态缓存 painter：播放中每帧都在更新 [position]，仅位置变化
/// 时走 [KaraokeLinePainter.withPosition] 共享排版结果（不重新 layout），
/// 排版参数（行/样式/颜色/约束）变化时才重建并释放旧 painter 的原生资源。
class LyricText extends StatefulWidget {
  const LyricText({
    super.key,
    required this.line,
    required this.active,
    required this.position,
    this.styleOverride,
    this.textAlign = TextAlign.start,
    this.singleLine = false,
  });

  final LyricLine line;
  final bool active;
  final Duration position;
  final TextStyle? styleOverride;
  final TextAlign textAlign;
  final bool singleLine;

  @override
  State<LyricText> createState() => _LyricTextState();
}

class _LyricTextState extends State<LyricText> {
  KaraokeLinePainter? _painter;

  @override
  void dispose() {
    _painter?.release();
    _painter = null;
    super.dispose();
  }

  KaraokeLinePainter _painterFor({
    required TextStyle style,
    required TextDirection textDirection,
    required TextAlign textAlign,
    required int? maxLines,
    required double maxWidth,
  }) {
    const baseColor = Color.fromRGBO(255, 255, 255, 0.34);
    const activeColor = Colors.white;
    final old = _painter;
    if (old != null &&
        old.line == widget.line &&
        old.style == style &&
        old.baseColor == baseColor &&
        old.activeColor == activeColor &&
        old.textDirection == textDirection &&
        old.textAlign == textAlign &&
        old.maxLines == maxLines &&
        old.maxWidth == maxWidth) {
      // 仅位置变化：复用排版，生成轻量副本驱动重绘。
      if (old.position == widget.position) return old;
      _painter = old.withPosition(widget.position);
      return _painter!;
    }
    old?.release();
    _painter = KaraokeLinePainter(
      line: widget.line,
      position: widget.position,
      style: style,
      baseColor: baseColor,
      activeColor: activeColor,
      textDirection: textDirection,
      textAlign: textAlign,
      maxLines: maxLines,
      maxWidth: maxWidth,
    );
    return _painter!;
  }

  @override
  Widget build(BuildContext context) {
    final style =
        widget.styleOverride ??
        Theme.of(context).textTheme.headlineMedium!.copyWith(
          color: Colors.white,
          fontSize: widget.active ? 34 : 27,
          height: 1.24,
          fontWeight: widget.active ? FontWeight.w900 : FontWeight.w800,
        );

    if (!widget.active || widget.line.words.isEmpty) {
      // 退出卡拉OK态（切行/无逐字时间）：释放缓存的排版资源。
      _painter?.release();
      _painter = null;
      if (widget.singleLine) {
        return Text(
          widget.line.text,
          textAlign: widget.textAlign,
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.visible,
          style: style,
        );
      }
      return Text(widget.line.text, textAlign: widget.textAlign, style: style);
    }

    if (widget.singleLine) {
      final painter = _painterFor(
        style: style,
        textDirection: Directionality.of(context),
        textAlign: widget.textAlign,
        maxLines: 1,
        maxWidth: double.infinity,
      );
      return CustomPaint(
        size: Size(painter.width, painter.height),
        painter: painter,
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final painter = _painterFor(
          style: style,
          textDirection: Directionality.of(context),
          textAlign: widget.textAlign,
          maxLines: null,
          maxWidth: constraints.maxWidth,
        );
        return CustomPaint(
          size: Size(constraints.maxWidth, painter.height),
          painter: painter,
        );
      },
    );
  }
}
