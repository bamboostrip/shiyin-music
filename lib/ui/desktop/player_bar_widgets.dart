import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../controllers/player_controller.dart';

/// 桌面播放条增强部件与纯逻辑：播放模式按钮、音量图标交互、进度悬停时间气泡。
///
/// 播放状态一律读写 [PlayerController] 同一字段（与全屏播放页/车机面板同源），
/// 本文件不持有播放状态；可单测的换算逻辑全部抽成顶层纯函数。

/// 音量滚轮单次步进（±5%，与 ↑/↓ 快捷键一致）。
const double kVolumeWheelStep = 0.05;

/// 取消静音但没有记忆音量时恢复的默认值。
const double kDefaultRestoreVolume = 0.5;

/// 播放模式 → 图标（与全屏播放页 `_playbackModeIcon` 同语义）。
IconData playbackModeIcon(PlaybackMode mode) {
  return switch (mode) {
    PlaybackMode.playlistLoop => Icons.repeat_rounded,
    PlaybackMode.shuffle => Icons.shuffle_rounded,
    PlaybackMode.singleLoop => Icons.repeat_one_rounded,
  };
}

/// 播放模式 → 按钮提示：显示当前模式名并附带切换提示。
String playbackModeTooltip(PlaybackMode mode) {
  return switch (mode) {
    PlaybackMode.playlistLoop => '列表循环（点击切换）',
    PlaybackMode.shuffle => '随机播放（点击切换）',
    PlaybackMode.singleLoop => '单曲循环（点击切换）',
  };
}

/// 音量 → 图标：0 视为静音、<0.5 小音量、否则大音量。
IconData volumeIconFor(double volume) {
  if (volume <= 0) return Icons.volume_off_rounded;
  return volume < 0.5 ? Icons.volume_down_rounded : Icons.volume_up_rounded;
}

/// 点击音量图标的静音/取消静音换算：
/// 当前有音量 → 静音（返回 0，并记住当前音量）；
/// 当前无声 → 取消静音（恢复记忆音量，无记忆回退默认值）。
/// 返回 `(应设置的音量, 新的记忆值)`。
(double, double?) toggleMute(double currentVolume, double? remembered) {
  if (currentVolume > 0) {
    return (0.0, currentVolume.clamp(0.0, 1.0));
  }
  final restored = (remembered ?? kDefaultRestoreVolume).clamp(0.0, 1.0);
  return (restored, remembered);
}

/// 滚轮步进后的音量：向上（scrollDelta.dy < 0）+ [step]、向下 -[step]，钳制 0..1。
double applyVolumeWheel(
  double currentVolume,
  bool scrollUp, {
  double step = kVolumeWheelStep,
}) {
  return (currentVolume + (scrollUp ? step : -step)).clamp(0.0, 1.0);
}

/// 进度条悬停横坐标 → 该位置对应的时间点；横坐标越界按两端钳制，
/// 宽度或时长非法时返回 0。
Duration positionForHover(double localX, double trackWidth, Duration duration) {
  if (trackWidth <= 0 || duration <= Duration.zero) return Duration.zero;
  final fraction = (localX / trackWidth).clamp(0.0, 1.0);
  return Duration(milliseconds: (duration.inMilliseconds * fraction).round());
}

/// 播放模式按钮：图标随模式变化，tooltip 提示当前模式（含切换提示）。
///
/// 直接调用 [PlayerController.cyclePlaybackMode]，与全屏播放页共用同一状态。
class PlayModeButton extends StatelessWidget {
  const PlayModeButton({super.key, required this.player, this.iconSize = 22});

  final PlayerController player;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: playbackModeTooltip(player.playbackMode),
      onPressed: player.cyclePlaybackMode,
      icon: Icon(playbackModeIcon(player.playbackMode), size: iconSize),
      color: Theme.of(context).colorScheme.onSurface,
    );
  }
}

/// 音量图标按钮：点击静音/取消静音（记忆静音前音量），滚轮 ±5% 微调。
///
/// 音量条拖拽仍由播放条里音量区的 Slider 负责，二者写同一音量字段。
class VolumeIconButton extends StatefulWidget {
  const VolumeIconButton({
    super.key,
    required this.player,
    this.iconSize = 20,
  });

  final PlayerController player;
  final double iconSize;

  @override
  State<VolumeIconButton> createState() => _VolumeIconButtonState();
}

class _VolumeIconButtonState extends State<VolumeIconButton> {
  double? _volumeBeforeMute;

  void _handlePointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    // 滚轮向上（scrollDelta.dy < 0）增大音量，向下减小。
    widget.player
        .setVolume(applyVolumeWheel(widget.player.volume, event.scrollDelta.dy < 0));
  }

  void _handleTap() {
    final (volume, memory) = toggleMute(widget.player.volume, _volumeBeforeMute);
    setState(() => _volumeBeforeMute = memory);
    widget.player.setVolume(volume);
  }

  @override
  Widget build(BuildContext context) {
    final volume = widget.player.volume.clamp(0.0, 1.0);
    return Tooltip(
      message: volume <= 0 ? '取消静音' : '静音',
      child: Listener(
        onPointerSignal: _handlePointerSignal,
        child: InkWell(
          onTap: _handleTap,
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Icon(
              volumeIconFor(volume),
              size: widget.iconSize,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}

/// 进度条悬停时间气泡：鼠标在 [child]（进度条）上移动时，上方跟随显示
/// 悬停位置对应的时间；离开即消失。
///
/// [showBubble] 为 false（拖拽中或无时长）时不渲染气泡，只保留子组件行为。
class HoverTimeBubble extends StatefulWidget {
  const HoverTimeBubble({
    super.key,
    required this.duration,
    required this.showBubble,
    required this.formatDuration,
    required this.child,
  });

  /// 曲目总时长，用于把悬停横坐标换算成时间。
  final Duration duration;

  /// 是否允许显示气泡（拖拽中传 false）。
  final bool showBubble;

  /// 秒数 → 文案（复用播放条的 `formatDuration`）。
  final String Function(Duration) formatDuration;

  final Widget child;

  @override
  State<HoverTimeBubble> createState() => _HoverTimeBubbleState();
}

class _HoverTimeBubbleState extends State<HoverTimeBubble> {
  double? _hoverX;

  /// 悬停时记录的子组件（进度条）实际宽度；
  /// 不能用 LayoutBuilder——进度条位于 mainAxisSize.min 的 Row 里，
  /// 其 maxWidth 约束是无界的，需要读取渲染盒真实尺寸。
  double _trackWidth = 0;

  bool get _visible =>
      widget.showBubble &&
      widget.duration > Duration.zero &&
      _hoverX != null;

  void _onHover(PointerEvent event) {
    final box = context.findRenderObject();
    setState(() {
      _hoverX = event.localPosition.dx;
      if (box is RenderBox && box.hasSize) {
        _trackWidth = box.size.width;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return MouseRegion(
      onHover: _onHover,
      onExit: (_) => setState(() => _hoverX = null),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          widget.child,
          if (_visible)
            Positioned(
              top: 0,
              left: _hoverX!.clamp(0.0, _trackWidth),
              child: FractionalTranslation(
                translation: const Offset(-0.5, 0),
                child: Container(
                  // 供 widget 测试定位气泡。
                  key: const ValueKey('hover_time_bubble'),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: colorScheme.inverseSurface,
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: Text(
                    widget.formatDuration(
                      positionForHover(
                        _hoverX!,
                        _trackWidth,
                        widget.duration,
                      ),
                    ),
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      color: colorScheme.onInverseSurface,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
