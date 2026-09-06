import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';

import '../../models/music_models.dart';

class ArtworkBackground extends StatefulWidget {
  const ArtworkBackground({super.key, required this.song});

  final Song song;

  @override
  State<ArtworkBackground> createState() => _ArtworkBackgroundState();
}

class _ArtworkBackgroundState extends State<ArtworkBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _rotationController;

  @override
  void initState() {
    super.initState();
    _rotationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 40), // 40 seconds for a full rotation
    )..repeat();
  }

  @override
  void dispose() {
    _rotationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final coverUrl = widget.song.coverUrl;
    final size = MediaQuery.sizeOf(context);
    final maxDim = math.max(size.width, size.height);
    final squareSize = maxDim * 1.2;

    // 旋转动画背景是纯装饰性的，排除语义树防止 Windows AXTree 竞态崩溃
    return ExcludeSemantics(
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 始终显示渐变兜底背景，避免封面加载期间出现纯黑背景
          const FallbackBackground(),
          if (coverUrl != null)
            OverflowBox(
              maxWidth: squareSize,
              maxHeight: squareSize,
              minWidth: squareSize,
              minHeight: squareSize,
              child: ImageFiltered(
                imageFilter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                child: RotationTransition(
                  turns: _rotationController,
                  child: Image.network(
                    coverUrl,
                    fit: BoxFit.cover,
                    cacheWidth: 100,
                    cacheHeight: 100,
                    errorBuilder: (context, error, stackTrace) =>
                        const SizedBox.shrink(),
                  ),
                ),
              ),
            ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withValues(alpha: .32),
                  Colors.black.withValues(alpha: .56),
                  Colors.black.withValues(alpha: .82),
                ],
              ),
            ),
          ),
          ColoredBox(color: Colors.black.withValues(alpha: .12)),
        ],
      ),
    );
  }
}

class FallbackBackground extends StatelessWidget {
  const FallbackBackground({super.key});

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF153D35), Color(0xFF061219), Color(0xFF2C1320)],
        ),
      ),
    );
  }
}
