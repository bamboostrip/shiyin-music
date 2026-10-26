import 'package:flutter/material.dart';

import '../../controllers/player_controller.dart';
import 'artwork.dart';

/// 旋转唱片 + 外圈环形播放进度（对齐上游 3.2.0 的
/// `MiniPlayer` / `_CenterPlayerDisc` 视觉与交互）。
///
/// 性能设计（本 fork 的车机/低端机红线，改动前先读）：
/// - 进度环只订阅 [PlayerController.positionListenable]（与旧线性进度条同频，
///   约每 200ms 一次），不参与逐帧重绘；
/// - 封面旋转由 24s/圈的 [AnimationController] 驱动 `RotationTransition`，
///   仅在「播放中 + App 前台 + 系统未开启减少动画」时 repeat；暂停/后台立即停；
/// - 旋转子树包 [RepaintBoundary]：每帧只更新 38~42px 图层的变换矩阵，
///   不重绘封面、不重新解码图片；
/// - 页面被不透明路由盖住时 Flutter Overlay 会把该路由的 TickerMode 置 false，
///   [TickerProviderStateMixin] 的 Ticker 自动静音，不会在后台页面空转；
/// - 不使用 BackdropFilter（上游液态玻璃依赖离屏合成，本项目已在 388ad96
///   为车机/低端机移除迷你条 blur，这里保持零离屏缓冲）。
class NowPlayingDisc extends StatefulWidget {
  const NowPlayingDisc({
    super.key,
    required this.player,
    required this.ringSize,
    required this.coverSize,
    this.strokeWidth = 2.2,
    this.ringBackgroundColor,
    this.showTransportIcon = false,
    this.showVinylDetail = true,
    this.coverBorder,
  }) : assert(coverSize < ringSize);

  final PlayerController player;

  /// 环形进度的外径（含进度环）。
  final double ringSize;

  /// 内部圆形封面直径。
  final double coverSize;

  final double strokeWidth;

  /// 进度环底色；null 为透明（上游样式）。
  final Color? ringBackgroundColor;

  /// 是否叠加播放/暂停小图标（首页底栏唱片沿用该交互提示）。
  final bool showTransportIcon;

  /// 是否绘制黑胶细节（同心圆边缘纹理）。
  final bool showVinylDetail;

  /// 封面外描边（首页底栏唱片的白圈）。
  final BorderSide? coverBorder;

  @override
  State<NowPlayingDisc> createState() => _NowPlayingDiscState();
}

class _NowPlayingDiscState extends State<NowPlayingDisc>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  /// 一圈 24 秒：与上游一致，慢速旋转不晃眼。
  static const _rotationPeriod = Duration(seconds: 24);

  late final AnimationController _rotation;
  bool _appInBackground = false;
  bool _reduceMotion = false;

  @override
  void initState() {
    super.initState();
    _rotation = AnimationController(vsync: this, duration: _rotationPeriod);
    WidgetsBinding.instance.addObserver(this);
    _syncRotation();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 尊重系统「减少动画」无障碍设置：静态封面，不跑 ticker。
    _reduceMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    _syncRotation();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appInBackground = state != AppLifecycleState.resumed;
    _syncRotation();
  }

  @override
  void didUpdateWidget(covariant NowPlayingDisc oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncRotation();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _rotation.dispose();
    super.dispose();
  }

  void _syncRotation() {
    final shouldRotate =
        widget.player.isPlaying && !_appInBackground && !_reduceMotion;
    if (shouldRotate) {
      if (!_rotation.isAnimating) {
        _rotation.repeat();
      }
    } else if (_rotation.isAnimating) {
      _rotation.stop(canceled: false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final coverSize = widget.coverSize;

    return AnimatedBuilder(
      animation: widget.player,
      builder: (context, _) {
        // 播放状态变化（play/pause/切歌）即时同步旋转。
        _syncRotation();
        final song = widget.player.currentSong;
        final hasSong = song != null;

        return Semantics(
          container: true,
          label: hasSong
              ? '正在播放：${song.title} - ${song.artist}'
              : '暂无播放歌曲',
          child: SizedBox.square(
            dimension: widget.ringSize,
            child: Stack(
              alignment: Alignment.center,
              children: [
                // 1. 外圈环形进度：只随 positionListenable 更新，不跑逐帧动画。
                ValueListenableBuilder<Duration>(
                  valueListenable: widget.player.positionListenable,
                  builder: (context, position, _) {
                    final durationMs = widget.player.duration.inMilliseconds;
                    final positionMs = position.inMilliseconds;
                    final progress = (durationMs > 0 && hasSong
                            ? positionMs / durationMs
                            : 0.0)
                        .clamp(0.0, 1.0);
                    // 播放失败时进度环转成错误色：圆盘没有文字槽位，红色环
                    // 是唯一不撑大布局的错误反馈（详情/短文案沿用此约定）。
                    final ringColor = widget.player.errorMessage != null
                        ? colorScheme.error
                        : colorScheme.primary;
                    return SizedBox.square(
                      dimension: widget.ringSize,
                      child: CircularProgressIndicator(
                        value: hasSong ? progress : 0.0,
                        strokeWidth: widget.strokeWidth,
                        strokeCap: StrokeCap.round,
                        valueColor: AlwaysStoppedAnimation<Color>(ringColor),
                        backgroundColor:
                            widget.ringBackgroundColor ?? Colors.transparent,
                      ),
                    );
                  },
                ),
                // 2. 黑胶唱片/专辑封面（播放中旋转，RepaintBoundary 隔离重绘）。
                Container(
                  width: coverSize,
                  height: coverSize,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: widget.coverBorder == null
                        ? null
                        : Border.fromBorderSide(widget.coverBorder!),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: .20),
                        blurRadius: 6,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: ClipOval(
                    child: hasSong
                        ? RepaintBoundary(
                            child: RotationTransition(
                              turns: _rotation,
                              child: Stack(
                                alignment: Alignment.center,
                                children: [
                                  Artwork(
                                    url: song.coverUrl,
                                    size: coverSize,
                                    borderRadius: coverSize / 2,
                                  ),
                                  if (widget.showVinylDetail) ...[
                                    // 唱片同心圆边缘纹理（不再画中心轴孔：
                                    // 详情页圆盘没有播放暂停叠层，中心点会显得
                                    // 像脏点，用户反馈后移除）。
                                    DecoratedBox(
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        border: Border.all(
                                          color: Colors.white.withValues(
                                            alpha: .25,
                                          ),
                                          width: .8,
                                        ),
                                      ),
                                      child: const SizedBox.expand(),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          )
                        : Container(
                            color: colorScheme.surfaceContainerHighest,
                            child: Icon(
                              Icons.music_note_rounded,
                              size: coverSize * .45,
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                  ),
                ),
                // 3. 可选播放/暂停小图标（首页底栏唱片）。
                if (widget.showTransportIcon && hasSong)
                  Container(
                    width: 18,
                    height: 18,
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: .45),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      widget.player.isPlaying
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                      size: 12,
                      color: Colors.white,
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
