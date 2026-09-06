import 'package:flutter/material.dart';

import '../../controllers/auth_controller.dart';
import '../../controllers/player_controller.dart';
import '../../controllers/theme_controller.dart';
import '../../models/music_models.dart';
import '../form_factor.dart';
import '../widgets/audio_quality_sheet.dart';
import '../widgets/climax_slider_track.dart';
import '../widgets/desktop_anchored_menu.dart';
import '../widgets/toast.dart';

Future<void> showAudioQualityPicker(
  BuildContext context,
  PlayerController player, {
  Offset? anchor,
}) async {
  final quality = await showAudioQualitySheet(
    context: context,
    selected: player.audioQuality,
    title: '切换音质',
    subtitle: '会重新加载当前歌曲并尽量保持播放进度',
    anchor: anchor,
  );
  if (quality == null) {
    return;
  }

  await player.setAudioQuality(quality, reloadCurrent: true);
  Toast.success('已切换到 ${quality.label}');
}

class PlayerAudioQualityPill extends StatelessWidget {
  const PlayerAudioQualityPill({
    super.key,
    required this.player,
    this.compact = false,
  });

  final PlayerController player;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: player,
      builder: (context, _) {
        final quality = player.audioQuality;
        final isLossless = quality == AudioQuality.lossless;
        final label = switch (quality) {
          AudioQuality.standard => '标准',
          AudioQuality.high => '高品',
          AudioQuality.lossless => '无损',
        };
        final tooltip = '音质：${quality.label} (${quality.badge}) - 点击切换';

        return Tooltip(
          message: tooltip,
          child: Material(
            color: Colors.white.withValues(alpha: .14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(
                color: isLossless
                    ? Theme.of(
                        context,
                      ).colorScheme.primary.withValues(alpha: .6)
                    : Colors.white.withValues(alpha: .18),
                width: 0.8,
              ),
            ),
            clipBehavior: Clip.antiAlias,
            child: Builder(
              builder: (pillContext) => InkWell(
                mouseCursor: SystemMouseCursors.click,
                onTap: () {
                  final anchor = isDesktopFormFactor
                      ? anchorBelow(pillContext)
                      : null;
                  showAudioQualityPicker(pillContext, player, anchor: anchor);
                },
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: compact ? 8 : 10,
                    vertical: compact ? 4 : 6,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (isLossless) ...[
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 3,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: Theme.of(
                              context,
                            ).colorScheme.primary.withValues(alpha: .28),
                            borderRadius: BorderRadius.circular(3),
                          ),
                          child: Text(
                            'SQ',
                            style: TextStyle(
                              fontSize: compact ? 8 : 9,
                              fontWeight: FontWeight.w900,
                              color: Theme.of(context).colorScheme.primary,
                              height: 1.1,
                            ),
                          ),
                        ),
                        const SizedBox(width: 4),
                      ],
                      Text(
                        label,
                        style: TextStyle(
                          fontSize: compact ? 11 : 12,
                          fontWeight: FontWeight.w700,
                          color: Colors.white.withValues(alpha: .92),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class Progress extends StatelessWidget {
  const Progress({
    super.key,
    required this.player,
    this.bright = false,
    this.compact = false,
  });

  final PlayerController player;
  final bool bright;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final textColor = bright
        ? Colors.white.withValues(alpha: .64)
        : Theme.of(context).colorScheme.onSurfaceVariant;

    return ValueListenableBuilder<Duration>(
      valueListenable: player.positionListenable,
      builder: (context, _, _) {
        final max = player.duration.inMilliseconds <= 0
            ? 1.0
            : player.duration.inMilliseconds.toDouble();
        final pos = player.smoothPosition;
        final value = pos.inMilliseconds.clamp(0, max.toInt()).toDouble();
        // 高潮起始位置映射为 0..1，在轨道内部画一个小标记。
        final climax = player.climax;
        final durationMs = player.duration.inMilliseconds;
        double? climaxStart;
        if (climax != null && climax.isValid && durationMs > 0) {
          final start = (climax.startTime.inMilliseconds / durationMs).clamp(
            0.0,
            1.0,
          );
          if (start > 0 && start < 1.0) {
            climaxStart = start;
          }
        }

        return Column(
          children: [
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: compact ? 3 : 5,
                thumbShape: RoundSliderThumbShape(
                  enabledThumbRadius: compact ? 4 : 5,
                ),
                overlayShape: RoundSliderOverlayShape(
                  overlayRadius: compact ? 10 : 14,
                ),
                activeTrackColor: bright
                    ? Colors.white.withValues(alpha: .86)
                    : Theme.of(context).colorScheme.primary,
                inactiveTrackColor: bright
                    ? Colors.white.withValues(alpha: .25)
                    : Theme.of(context).colorScheme.surfaceContainerHighest,
                thumbColor: Colors.white,
                trackShape: _ClimaxSliderTrackShape(
                  climaxStart: climaxStart,
                  markerColor: bright
                      ? Colors.white.withValues(alpha: .55)
                      : Theme.of(
                          context,
                        ).colorScheme.primary.withValues(alpha: .45),
                ),
              ),
              child: Slider(
                value: value,
                max: max,
                onChanged: (value) =>
                    player.previewSeek(Duration(milliseconds: value.round())),
                onChangeEnd: (value) async {
                  try {
                    await player.seek(
                      Duration(milliseconds: value.round()),
                    );
                  } catch (_) {
                    Toast.error('定位失败，请重试');
                  }
                },
              ),
            ),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: compact ? 2 : 4),
              child: Row(
                children: [
                  Text(
                    formatDuration(pos),
                    style: TextStyle(
                      color: textColor,
                      fontSize: compact ? 12 : null,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    formatDuration(player.duration),
                    style: TextStyle(
                      color: textColor,
                      fontSize: compact ? 12 : null,
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 播放页进度条的高潮标记轨道已抽到共享组件 [ClimaxSliderTrackShape]
/// （`lib/ui/widgets/climax_slider_track.dart`），与桌面底部播放栏共用，
/// 此处保留别名以收敛改动。
typedef _ClimaxSliderTrackShape = ClimaxSliderTrackShape;

class Controls extends StatelessWidget {
  const Controls({
    super.key,
    required this.player,
    required this.onQueue,
    this.bright = false,
    this.compactOverride = false,
    this.denseOverride = false,
    this.likeAuth,
    this.likeSong,
  });

  final PlayerController player;
  final VoidCallback onQueue;
  final bool bright;
  final bool compactOverride;
  final bool denseOverride;
  final AuthController? likeAuth;
  final Song? likeSong;

  @override
  Widget build(BuildContext context) {
    final color = bright
        ? Colors.white
        : Theme.of(context).colorScheme.onSurface;
    final size = MediaQuery.sizeOf(context);
    final isLandscape = size.width > size.height;

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = compactOverride || constraints.maxWidth < 360;
        final dense = denseOverride;
        // 超大按钮仅在车机模式开启时使用，普通横屏用标准尺寸。
        final isCar = isLandscape && ThemeController.instance.carModeEnabled;
        final edgeButtonSize = dense
            ? 34.0
            : (isCar ? 56.0 : (compact ? 40.0 : 44.0));
        final edgeIconSize = dense
            ? 21.0
            : (isCar ? 34.0 : (compact ? 24.0 : 27.0));
        final skipButtonSize = dense
            ? 42.0
            : (isCar ? 72.0 : (compact ? 50.0 : 56.0));
        final skipIconSize = dense
            ? 33.0
            : (isCar ? 54.0 : (compact ? 40.0 : 46.0));
        final playButtonSize = dense
            ? 58.0
            : (isCar ? 96.0 : (compact ? 72.0 : 82.0));
        final playIconSize = dense
            ? 46.0
            : (isCar ? 72.0 : (compact ? 56.0 : 64.0));
        final gap = dense ? 3.0 : (isCar ? 24.0 : (compact ? 5.0 : 9.0));
        final likeAuth = this.likeAuth;
        final likeSong = this.likeSong;
        final showLike = isCar && likeAuth != null && likeSong != null;

        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // 车机模式：爱心放在播放模式按钮左侧，方便近距离触控。
            if (showLike) ...[
              AnimatedBuilder(
                animation: likeAuth,
                builder: (context, _) {
                  final liked = likeAuth.isLiked(likeSong);
                  return SizedBox.square(
                    dimension: edgeButtonSize,
                    child: IconButton(
                      tooltip: liked ? '取消喜欢' : '喜欢',
                      color: color,
                      iconSize: edgeIconSize,
                      padding: EdgeInsets.zero,
                      onPressed: likeSong.source == SongSource.kugou
                          ? () => likeAuth.toggleLike(likeSong)
                          : null,
                      icon: Icon(
                        liked
                            ? Icons.favorite_rounded
                            : Icons.favorite_border_rounded,
                      ),
                    ),
                  );
                },
              ),
              SizedBox(width: gap),
            ],
            SizedBox.square(
              dimension: edgeButtonSize,
              child: IconButton(
                tooltip: player.playbackModeLabel,
                color: color,
                iconSize: edgeIconSize,
                padding: EdgeInsets.zero,
                onPressed: () {
                  player.cyclePlaybackMode();
                  Toast.show(
                    '已切换到${player.playbackModeLabel}',
                    duration: const Duration(milliseconds: 1100),
                  );
                },
                icon: Icon(_playbackModeIcon(player.playbackMode)),
              ),
            ),
            SizedBox(width: gap),
            SizedBox.square(
              dimension: skipButtonSize,
              child: IconButton(
                tooltip: '上一首',
                color: color,
                iconSize: skipIconSize,
                padding: EdgeInsets.zero,
                onPressed: player.previous,
                icon: const Icon(Icons.skip_previous_rounded),
              ),
            ),
            SizedBox(width: gap),
            SizedBox.square(
              dimension: playButtonSize,
              child: IconButton(
                tooltip: player.isPlaying ? '暂停' : '播放',
                color: color,
                padding: EdgeInsets.zero,
                onPressed: player.isPreparing ? null : player.togglePlay,
                iconSize: playIconSize,
                icon: player.isPreparing
                    ? SizedBox.square(
                        dimension: isCar ? 36 : (compact ? 24 : 28),
                        child: const CircularProgressIndicator(
                          strokeWidth: 3,
                          color: Colors.white,
                        ),
                      )
                    : Icon(
                        player.isPlaying
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                      ),
              ),
            ),
            SizedBox(width: gap),
            SizedBox.square(
              dimension: skipButtonSize,
              child: IconButton(
                tooltip: '下一首',
                color: color,
                iconSize: skipIconSize,
                padding: EdgeInsets.zero,
                onPressed: player.next,
                icon: const Icon(Icons.skip_next_rounded),
              ),
            ),
            SizedBox(width: gap),
            SizedBox.square(
              dimension: edgeButtonSize,
              child: IconButton(
                tooltip: '播放列表',
                color: color,
                iconSize: edgeIconSize,
                padding: EdgeInsets.zero,
                onPressed: onQueue,
                icon: const Icon(Icons.queue_music_rounded),
              ),
            ),
          ],
        );
      },
    );
  }

  IconData _playbackModeIcon(PlaybackMode mode) {
    return switch (mode) {
      PlaybackMode.playlistLoop => Icons.repeat_rounded,
      PlaybackMode.shuffle => Icons.shuffle_rounded,
      PlaybackMode.singleLoop => Icons.repeat_one_rounded,
    };
  }
}

class GlassIconButton extends StatelessWidget {
  const GlassIconButton({
    super.key,
    required this.tooltip,
    required this.onPressed,
    required this.icon,
  });

  final String tooltip;
  final VoidCallback? onPressed;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.white.withValues(alpha: .14),
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: IconButton(
          color: Colors.white,
          onPressed: onPressed,
          icon: Icon(icon),
        ),
      ),
    );
  }
}
