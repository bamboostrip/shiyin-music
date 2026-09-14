import 'package:flutter/material.dart';

class NowPlayingBadge extends StatefulWidget {
  const NowPlayingBadge({
    super.key,
    required this.active,
    required this.playing,
    required this.color,
    this.size = 18,
    this.barCount = 3,
  });

  final bool active;
  final bool playing;
  final Color color;
  final double size;
  final int barCount;

  @override
  State<NowPlayingBadge> createState() => _NowPlayingBadgeState();
}

class _NowPlayingBadgeState extends State<NowPlayingBadge>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 820),
    );
    _syncAnimation();
  }

  @override
  void didUpdateWidget(covariant NowPlayingBadge oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncAnimation();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _syncAnimation() {
    if (widget.active && widget.playing) {
      if (!_controller.isAnimating) {
        _controller.repeat(reverse: true);
      }
    } else if (_controller.isAnimating) {
      _controller.stop(canceled: false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.active) {
      return SizedBox.square(dimension: widget.size);
    }

    return SizedBox.square(
      dimension: widget.size,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          return CustomPaint(
            painter: NowPlayingPainter(
              progress: widget.playing ? _controller.value : .42,
              color: widget.color,
              barCount: widget.barCount,
            ),
          );
        },
      ),
    );
  }
}

@visibleForTesting
class NowPlayingPainter extends CustomPainter {
  const NowPlayingPainter({
    required this.progress,
    required this.color,
    this.barCount = 3,
  });

  final double progress;
  final Color color;
  final int barCount;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    final count = barCount;
    final barWidth = size.width / (count + (count - 1) * 0.5);
    final gap = barWidth * 0.5;
    final List<double> values;
    if (count == 4) {
      values = [
        .32 + .48 * progress,
        .88 - .45 * progress,
        .45 + .50 * (1 - (progress - .5).abs() * 2),
        .35 + .35 * (progress > .5 ? 1 - progress : progress) * 2,
      ];
    } else {
      values = [
        .42 + .36 * progress,
        .72 - .28 * progress,
        .48 + .44 * (1 - (progress - .5).abs() * 2),
      ];
    }

    for (var i = 0; i < values.length; i++) {
      final height = size.height * values[i].clamp(.25, .95);
      final left = i * (barWidth + gap);
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(left, size.height - height, barWidth, height),
        Radius.circular(barWidth / 2),
      );
      canvas.drawRRect(rect, paint);
    }
  }

  @override
  bool shouldRepaint(covariant NowPlayingPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.color != color ||
        oldDelegate.barCount != barCount;
  }
}
