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
  /// 暂停或窗口不可见（最小化/后台，音乐还在放）时冻结在当前角度，
  /// 纯装饰动画暂停不动无可感知差异。
  final bool playing;

  @override
  State<ArtworkBackground> createState() => _ArtworkBackgroundState();
}

class _ArtworkBackgroundState extends State<ArtworkBackground>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _rotationController;
  bool _appHidden = false;

  @override
  void initState() {
    super.initState();
    _rotationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 40), // 40 seconds for a full rotation
    );
    WidgetsBinding.instance.addObserver(this);
    // 组件可能在应用已不可见时才构建（如后台期间换歌重建），从当前
    // 生命周期初始化，避免首帧先转起来再等回调纠正。
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _appHidden = lifecycle != null && _isHiddenState(lifecycle);
    _syncRotation();
  }

  /// 仅在窗口真正不可见（hidden/paused/detached）时冻结：最小化后桌面端
  /// 仍会继续出帧，空跑全屏模糊是切桌面掉帧的来源。仅失焦（inactive）
  /// 但窗口可见时保持旋转——桌面端多软件并排是常态，转着更自然；
  /// 移动端 inactive 只是通知栏下拉等仍可见的瞬时态，不受影响。
  static bool _isHiddenState(AppLifecycleState state) =>
      state != AppLifecycleState.resumed && state != AppLifecycleState.inactive;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appHidden = _isHiddenState(state);
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
    if (widget.playing && !_appHidden) {
      if (!_rotationController.isAnimating) {
        _rotationController.repeat();
      }
    } else if (_rotationController.isAnimating) {
      _rotationController.stop(canceled: false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
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
