import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';

import '../../models/music_models.dart';
import '../form_factor.dart';
import '../widgets/artwork.dart';

class ArtworkBackground extends StatefulWidget {
  const ArtworkBackground({super.key, required this.song, this.playing = true});

  final Song song;

  /// 是否正在播放：旋转+全屏模糊背景按显示刷新率持续消耗 GPU，
  /// 暂停时冻结在当前角度（纯装饰动画，暂停不动无可感知差异）。
  final bool playing;

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
    );
    _syncRotation();
  }

  @override
  void didUpdateWidget(covariant ArtworkBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.playing != widget.playing) {
      _syncRotation();
    }
  }

  void _syncRotation() {
    if (widget.playing) {
      if (!_rotationController.isAnimating) {
        _rotationController.repeat();
      }
    } else if (_rotationController.isAnimating) {
      _rotationController.stop(canceled: false);
    }
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

    // 旋转动画背景是纯装饰性的，仅桌面 Windows 排除语义树（AXTree 竞态）
    return ExcludeSemantics(
      excluding: isDesktopPlatform,
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
                  // 走磁盘缓存链路：重进播放页时背景从本地字节秒出，
                  // 不再等网络往返（重模糊 + 渐变兜底下网络闪烁原本就不明显，
                  // 磁盘命中后这一帧也不再有）。
                  child: RetryableNetworkImage(
                    url: coverUrl,
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
