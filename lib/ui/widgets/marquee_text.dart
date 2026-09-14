import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show OverflowBoxFit;

/// A reusable marquee text widget that smoothly scrolls overflowing text
/// in a ping-pong manner with pauses at the start and end boundaries.
///
/// When the text fits within the available width, it renders static [Text.rich]
/// with zero animation overhead.
class MarqueeText extends StatefulWidget {
  const MarqueeText({
    super.key,
    required this.textSpan,
    this.style,
    this.velocity = 30.0,
    this.pauseDuration = const Duration(seconds: 2),
    this.curve = Curves.linear,
  });

  /// Convenience factory constructor for plain text strings.
  factory MarqueeText.text(
    String text, {
    Key? key,
    TextStyle? style,
    double velocity = 30.0,
    Duration pauseDuration = const Duration(seconds: 2),
    Curve curve = Curves.linear,
  }) {
    return MarqueeText(
      key: key,
      textSpan: TextSpan(text: text),
      style: style,
      velocity: velocity,
      pauseDuration: pauseDuration,
      curve: curve,
    );
  }

  /// The text content to display, supporting rich styling.
  final InlineSpan textSpan;

  /// Optional text style merged with default text style.
  final TextStyle? style;

  /// Scroll speed in pixels per second.
  final double velocity;

  /// Duration to pause at the start and end boundaries.
  final Duration pauseDuration;

  /// Curve applied during the forward and backward scrolling phases.
  final Curve curve;

  @override
  State<MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<MarqueeText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  Animation<double>? _animation;

  /// 暂停相位用 Timer 而非持续 repeat 的 ticker 承载：跑马灯在两端的
  /// 停留期（默认各 2s）不需要任何帧，避免桌面播放栏常驻 60fps 唤醒。
  Timer? _pauseTimer;

  /// 当前是否处于回滚半程（reverse 完成 fires dismissed，reset 也会，
  /// 用此标记区分"回滚到位"与"人为归零"）。
  bool _reversing = false;

  double? _lastOverflow;
  Duration? _lastPauseDuration;
  double? _lastVelocity;
  Curve? _lastCurve;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this)
      ..addStatusListener(_onStatusChanged);
  }

  @override
  void dispose() {
    _pauseTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onStatusChanged(AnimationStatus status) {
    final isForwardEnd = status == AnimationStatus.completed;
    final isReverseEnd = status == AnimationStatus.dismissed && _reversing;
    if (!isForwardEnd && !isReverseEnd) return;
    _schedulePause(nextReverse: isForwardEnd);
  }

  void _schedulePause({required bool nextReverse}) {
    _pauseTimer?.cancel();
    final pause =
        widget.pauseDuration < Duration.zero
            ? Duration.zero
            : widget.pauseDuration;
    _pauseTimer = Timer(pause, () {
      if (!mounted) return;
      if (nextReverse) {
        _reversing = true;
        _controller.reverse();
      } else {
        _reversing = false;
        _controller.forward();
      }
    });
  }

  /// 从起点重新开始一个乒乓周期（起始端先停留 [MarqueeText.pauseDuration]）。
  void _startCycle() {
    _pauseTimer?.cancel();
    _reversing = false;
    _controller.reset();
    _schedulePause(nextReverse: false);
  }

  void _stopCycle() {
    _pauseTimer?.cancel();
    _reversing = false;
    if (_controller.isAnimating) {
      _controller.stop();
    }
    _controller.reset();
  }

  @override
  Widget build(BuildContext context) {
    final textDirection = Directionality.maybeOf(context) ?? TextDirection.ltr;
    final textScaler =
        MediaQuery.maybeTextScalerOf(context) ?? TextScaler.noScaling;
    final defaultStyle = DefaultTextStyle.of(context).style;
    final effectiveStyle =
        widget.style != null ? defaultStyle.merge(widget.style) : defaultStyle;

    final InlineSpan measuredSpan;
    if (widget.textSpan is TextSpan) {
      final span = widget.textSpan as TextSpan;
      measuredSpan = TextSpan(
        text: span.text,
        children: span.children,
        style: span.style != null
            ? effectiveStyle.merge(span.style)
            : effectiveStyle,
        recognizer: span.recognizer,
        semanticsLabel: span.semanticsLabel,
      );
    } else {
      measuredSpan = TextSpan(
        style: effectiveStyle,
        children: [widget.textSpan],
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final availableWidth = constraints.maxWidth;

        final painter = TextPainter(
          text: measuredSpan,
          textDirection: textDirection,
          textScaler: textScaler,
          maxLines: 1,
        )..layout();

        final textWidth = painter.width.ceilToDouble();
        painter.dispose();

        final overflow = textWidth - availableWidth;

        // If text fits in available width (or width is unconstrained):
        // Render static Text.rich with 0 animation overhead.
        if (availableWidth.isInfinite || overflow <= 0) {
          if (_controller.isAnimating || _pauseTimer != null) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && (_controller.isAnimating || _pauseTimer != null)) {
                _stopCycle();
              }
            });
          }
          _lastOverflow = null;
          return Text.rich(
            widget.textSpan,
            style: widget.style,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.clip,
          );
        }

        // Text overflows available width: ping-pong smooth horizontal scroll.
        final velocity = widget.velocity > 0 ? widget.velocity : 30.0;
        final pauseDuration =
            widget.pauseDuration < Duration.zero
                ? Duration.zero
                : widget.pauseDuration;
        final moveDurationMs = (overflow / velocity * 1000).round();
        final moveDuration = Duration(
          milliseconds: moveDurationMs > 0 ? moveDurationMs : 1,
        );

        // 触发条件只看"影响滚动几何/时序"的量。刻意不做 textSpan/style 的
        // 实例比较：调用方（播放栏）每次重建都会 new 一个 TextSpan，身份
        // 比较会让无关重建（音量调节、播放暂停、hover）把滚动打回起点；
        // 文本/样式变化必然反映到 overflow（宽度变化）或实时渲染子树，
        // 无需单独感知。
        final needsUpdate =
            _lastOverflow != overflow ||
            _lastPauseDuration != pauseDuration ||
            _lastVelocity != velocity ||
            _lastCurve != widget.curve ||
            _animation == null;

        if (needsUpdate) {
          _lastOverflow = overflow;
          _lastPauseDuration = pauseDuration;
          _lastVelocity = velocity;
          _lastCurve = widget.curve;

          _controller.duration = moveDuration;
          _animation = Tween<double>(begin: 0, end: -overflow)
              .chain(CurveTween(curve: widget.curve))
              .animate(_controller);

          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            _startCycle();
          });
        }

        return ClipRect(
          child: OverflowBox(
            alignment: Alignment.centerLeft,
            // deferToChild：自身尺寸跟随子项（有限文本高），再用父级约束
            // constrain。默认 fit:max 会 size=constraints.biggest——播放栏
            // 左区 Column(mainAxisSize.min) 给的是无界高度，biggest 高度
            // 为 Infinity，触发 RenderBox 断言崩溃。
            fit: OverflowBoxFit.deferToChild,
            minWidth: textWidth,
            maxWidth: textWidth,
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, child) {
                final offset = _animation?.value ?? 0.0;
                return Transform.translate(
                  offset: Offset(offset, 0),
                  child: child,
                );
              },
              child: Text.rich(
                widget.textSpan,
                style: widget.style,
                maxLines: 1,
                softWrap: false,
              ),
            ),
          ),
        );
      },
    );
  }
}
