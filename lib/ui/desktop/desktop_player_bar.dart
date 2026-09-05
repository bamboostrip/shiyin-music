import 'package:flutter/material.dart';

import '../../controllers/auth_controller.dart';
import '../../controllers/player_controller.dart';
import '../../models/music_models.dart';
import '../pages/player_page.dart';
import '../widgets/artwork.dart';
import '../widgets/audio_quality_sheet.dart';
import '../widgets/climax_slider_track.dart';
import '../widgets/desktop_queue_panel.dart';
import '../widgets/toast.dart';
import 'player_bar_widgets.dart';

/// 秒数 → `mm:ss`（≥1h 时 `h:mm:ss`）。
String formatDuration(Duration d) {
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  final h = d.inHours;
  return h > 0 ? '$h:$m:$s' : '$m:$s';
}

/// 桌面底部播放栏：封面/曲目信息 + 播放控制 + 进度 + 音量 + 队列。
///
/// 无歌曲时保持占位布局（高度稳定，不随播放状态跳变）。
/// 桌面歌词开关按钮由计划 3 在本文件追加。
class DesktopPlayerBar extends StatelessWidget {
  const DesktopPlayerBar({
    super.key,
    required this.player,
    required this.auth,
  });

  final PlayerController player;
  final AuthController auth;

  void _openPlayerPage(BuildContext context) {
    if (player.currentSong == null) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlayerPage(player: player, auth: auth),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return AnimatedBuilder(
      animation: player,
      builder: (context, _) {
        final song = player.currentSong;
        return Container(
          height: 72,
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF1E2433) : Colors.white,
            border: Border(
              top: BorderSide(
                color: colorScheme.outlineVariant.withValues(alpha: .5),
                width: 1,
              ),
            ),
          ),
          child: Row(
            children: [
              const SizedBox(width: 12),
              // 封面 + 曲目信息：点击进入播放页
              InkWell(
                onTap: () => _openPlayerPage(context),
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Row(
                    children: [
                      Artwork(
                        url: song?.coverUrl,
                        size: 48,
                        borderRadius: 8,
                      ),
                      const SizedBox(width: 12),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 200),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              song?.title ?? '尚未播放',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w800,
                                color: song == null
                                    ? colorScheme.onSurfaceVariant
                                    : colorScheme.onSurface,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              song?.artist ?? '去挑一首喜欢的歌吧',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const Spacer(),
              // 播放控制
              IconButton(
                tooltip: '上一首',
                onPressed: song == null ? null : player.previous,
                icon: const Icon(Icons.skip_previous_rounded, size: 28),
                color: colorScheme.onSurface,
              ),
              const SizedBox(width: 4),
              IconButton(
                tooltip: player.isPlaying ? '暂停' : '播放',
                onPressed: player.isPreparing || song == null
                    ? null
                    : player.togglePlay,
                icon: Icon(
                  player.isPlaying
                      ? Icons.pause_circle_rounded
                      : Icons.play_circle_rounded,
                  size: 40,
                ),
                color: colorScheme.primary,
              ),
              const SizedBox(width: 4),
              IconButton(
                tooltip: '下一首',
                onPressed: song == null ? null : player.next,
                icon: const Icon(Icons.skip_next_rounded, size: 28),
                color: colorScheme.onSurface,
              ),
              // 播放模式（与全屏播放页共用同一 controller 字段）
              const SizedBox(width: 4),
              PlayModeButton(player: player),
              const Spacer(),
              // 进度区（拖拽中显示拖拽位置，松手 seek）
              if (song != null) ...[
                _ProgressBar(player: player),
                const SizedBox(width: 16),
              ],
              // 音质切换
              _AudioQualityButton(
                key: const ValueKey('desktop_audio_quality_button'),
                player: player,
              ),
              const SizedBox(width: 8),
              // 音量
              _VolumeControl(player: player),
              const SizedBox(width: 8),
              // 桌面歌词开关（仅支持桌面歌词的平台渲染）
              if (player.isDesktopLyricsSupported) ...[
                AnimatedBuilder(
                  animation: player,
                  builder: (context, _) {
                    final enabled = player.desktopLyricsEnabled;
                    final locked = player.desktopLyricsLocked;
                    final String tooltip;
                    final IconData iconData;
                    final Color color;
                    final VoidCallback? onPressed;

                    if (enabled && locked) {
                      tooltip = '桌面歌词已锁定，点击一键解锁';
                      iconData = Icons.lock_rounded;
                      color = colorScheme.primary;
                      onPressed = song == null
                          ? null
                          : () => player.unlockDesktopLyrics();
                    } else if (enabled) {
                      tooltip = '关闭桌面歌词';
                      iconData = Icons.lyrics_rounded;
                      color = colorScheme.primary;
                      onPressed = song == null
                          ? null
                          : () => player.setDesktopLyricsEnabled(false);
                    } else {
                      tooltip = '开启桌面歌词';
                      iconData = Icons.lyrics_outlined;
                      color = colorScheme.onSurface;
                      onPressed = song == null
                          ? null
                          : () => player.setDesktopLyricsEnabled(true);
                    }

                    return IconButton(
                      tooltip: tooltip,
                      onPressed: onPressed,
                      icon: Icon(iconData, size: 26),
                      color: color,
                    );
                  },
                ),
                const SizedBox(width: 4),
              ],
              // 队列（PC：锚定在按钮上方的面板，替代移动端底部弹层）
              Builder(
                builder: (buttonContext) => IconButton(
                  tooltip: '播放队列',
                  onPressed: song == null
                      ? null
                      : () => showDesktopQueuePanel(buttonContext, player),
                  icon: const Icon(Icons.queue_music_rounded, size: 26),
                  color: colorScheme.onSurface,
                ),
              ),
              const SizedBox(width: 12),
            ],
          ),
        );
      },
    );
  }
}

class _ProgressBar extends StatefulWidget {
  const _ProgressBar({required this.player});

  final PlayerController player;

  @override
  State<_ProgressBar> createState() => _ProgressBarState();
}

class _ProgressBarState extends State<_ProgressBar> {
  double? _dragValue;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return ValueListenableBuilder<Duration>(
      valueListenable: widget.player.positionListenable,
      builder: (context, position, _) {
        final durationMs = widget.player.duration.inMilliseconds;
        final progress = _dragValue ??
            (durationMs > 0
                ? (position.inMilliseconds / durationMs).clamp(0.0, 1.0)
                : 0.0);
        final shownPosition = _dragValue != null && durationMs > 0
            ? Duration(milliseconds: (durationMs * _dragValue!).round())
            : position;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              formatDuration(shownPosition),
              style: TextStyle(
                fontSize: 11,
                fontFeatures: const [FontFeature.tabularFigures()],
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            // 悬停显示该位置时间气泡；拖拽中不显示（拖拽本身有位置反馈）。
            HoverTimeBubble(
              duration: widget.player.duration,
              showBubble: _dragValue == null && durationMs > 0,
              formatDuration: formatDuration,
              child: SizedBox(
                width: 280,
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 3,
                    thumbShape:
                        const RoundSliderThumbShape(enabledThumbRadius: 6),
                    overlayShape:
                        const RoundSliderOverlayShape(overlayRadius: 12),
                    // 高潮起始标记（与播放页同一套轨道，多端数据同源）。
                    trackShape: ClimaxSliderTrackShape(
                      climaxStart: climaxStartFraction(
                        climax: widget.player.climax,
                        durationMs: durationMs,
                      ),
                      markerColor:
                          colorScheme.primary.withValues(alpha: .45),
                    ),
                  ),
                  child: Slider(
                    value: progress,
                    onChanged: durationMs > 0
                        ? (value) => setState(() => _dragValue = value)
                        : null,
                    onChangeEnd: durationMs > 0
                        ? (value) {
                            widget.player.seek(
                              Duration(
                                milliseconds:
                                    (durationMs * value).round(),
                              ),
                            );
                            setState(() => _dragValue = null);
                          }
                        : null,
                  ),
                ),
              ),
            ),
            Text(
              formatDuration(widget.player.duration),
              style: TextStyle(
                fontSize: 11,
                fontFeatures: const [FontFeature.tabularFigures()],
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        );
      },
    );
  }
}

class _VolumeControl extends StatefulWidget {
  const _VolumeControl({required this.player});

  final PlayerController player;

  @override
  State<_VolumeControl> createState() => _VolumeControlState();
}

class _VolumeControlState extends State<_VolumeControl> {
  double? _dragValue;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.player,
      builder: (context, _) {
        // 拖拽中显示拖拽值，其余时刻跟随 player（快捷键/其他入口改动即时同步）。
        final volume =
            (_dragValue ?? widget.player.volume).clamp(0.0, 1.0);
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 点击静音/取消静音（记忆静音前音量），图标区滚轮 ±5%。
            VolumeIconButton(player: widget.player),
            SizedBox(
              width: 96,
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 3,
                  thumbShape:
                      const RoundSliderThumbShape(enabledThumbRadius: 6),
                  overlayShape:
                      const RoundSliderOverlayShape(overlayRadius: 12),
                ),
                child: Slider(
                  value: volume,
                  onChanged: (value) {
                    setState(() => _dragValue = value);
                    widget.player.setVolume(value);
                  },
                  onChangeEnd: (value) {
                    widget.player.setVolume(value);
                    setState(() => _dragValue = null);
                  },
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _AudioQualityButton extends StatelessWidget {
  const _AudioQualityButton({super.key, required this.player});

  final PlayerController player;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: player,
      builder: (context, _) {
        final song = player.currentSong;
        final quality = player.audioQuality;
        final enabled = song != null;
        final colorScheme = Theme.of(context).colorScheme;
        final isLossless = quality == AudioQuality.lossless;
        final label = switch (quality) {
          AudioQuality.standard => '标准',
          AudioQuality.high => '高品',
          AudioQuality.lossless => '无损',
        };
        final tooltip = '音质：${quality.label} (${quality.badge}) - 点击切换';

        final Color foregroundColor;
        final Color borderColor;
        if (!enabled) {
          foregroundColor = colorScheme.onSurface.withValues(alpha: .38);
          borderColor = colorScheme.outlineVariant.withValues(alpha: .38);
        } else if (isLossless) {
          foregroundColor = colorScheme.primary;
          borderColor = colorScheme.primary.withValues(alpha: .6);
        } else {
          foregroundColor = colorScheme.onSurfaceVariant;
          borderColor = colorScheme.outlineVariant;
        }

        return Tooltip(
          message: tooltip,
          child: Material(
            color: Colors.transparent,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
              side: BorderSide(color: borderColor, width: 1),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              mouseCursor: enabled
                  ? SystemMouseCursors.click
                  : SystemMouseCursors.basic,
              hoverColor:
                  (isLossless ? colorScheme.primary : colorScheme.onSurface)
                      .withValues(alpha: 0.08),
              onTap: enabled
                  ? () async {
                      final picked = await showAudioQualitySheet(
                        context: context,
                        selected: player.audioQuality,
                        title: '切换音质',
                        subtitle: '会重新加载当前歌曲并尽量保持播放进度',
                      );
                      if (picked != null) {
                        await player.setAudioQuality(
                          picked,
                          reloadCurrent: true,
                        );
                        Toast.success('已切换到 ${picked.label}');
                      }
                    }
                  : null,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 4,
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
                          color: foregroundColor.withValues(alpha: .15),
                          borderRadius: BorderRadius.circular(3),
                        ),
                        child: Text(
                          'SQ',
                          style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.w900,
                            color: foregroundColor,
                            height: 1.1,
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                    ],
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: foregroundColor,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
