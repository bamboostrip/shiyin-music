import 'package:flutter/material.dart';

import '../../controllers/auth_controller.dart';
import '../../controllers/player_controller.dart';
import '../pages/player_page.dart';
import '../widgets/artwork.dart';
import '../widgets/queue_sheet.dart';

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
              AnimatedBuilder(
                animation: player,
                builder: (context, _) {
                  final playing = player.isPlaying;
                  return IconButton(
                    tooltip: playing ? '暂停' : '播放',
                    onPressed: player.isPreparing || song == null
                        ? null
                        : player.togglePlay,
                    icon: Icon(
                      playing
                          ? Icons.pause_circle_rounded
                          : Icons.play_circle_rounded,
                      size: 40,
                    ),
                    color: colorScheme.primary,
                  );
                },
              ),
              const SizedBox(width: 4),
              IconButton(
                tooltip: '下一首',
                onPressed: song == null ? null : player.next,
                icon: const Icon(Icons.skip_next_rounded, size: 28),
                color: colorScheme.onSurface,
              ),
              const Spacer(),
              // 进度区（拖拽中显示拖拽位置，松手 seek）
              if (song != null) ...[
                _ProgressBar(player: player),
                const SizedBox(width: 16),
              ],
              // 音量
              const SizedBox(width: 8),
              _VolumeControl(player: player),
              const SizedBox(width: 8),
              // 队列
              IconButton(
                tooltip: '播放队列',
                onPressed: song == null
                    ? null
                    : () => showQueueSheet(context, player),
                icon: const Icon(Icons.queue_music_rounded, size: 26),
                color: colorScheme.onSurface,
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
            SizedBox(
              width: 280,
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 3,
                  thumbShape:
                      const RoundSliderThumbShape(enabledThumbRadius: 6),
                  overlayShape:
                      const RoundSliderOverlayShape(overlayRadius: 12),
                ),
                child: Slider(
                  value: progress,
                  onChanged: durationMs > 0
                      ? (value) => setState(() => _dragValue = value)
                      : null,
                  onChangeEnd: durationMs > 0
                      ? (value) {
                          widget.player.seek(
                            Duration(milliseconds: (durationMs * value).round()),
                          );
                          setState(() => _dragValue = null);
                        }
                      : null,
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
  late double _volume = widget.player.volume.clamp(0.0, 1.0);

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          _volume <= 0
              ? Icons.volume_off_rounded
              : _volume < 0.5
                  ? Icons.volume_down_rounded
                  : Icons.volume_up_rounded,
          size: 20,
          color: colorScheme.onSurfaceVariant,
        ),
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
              value: _volume,
              onChanged: (value) {
                setState(() => _volume = value);
                widget.player.setVolume(value);
              },
            ),
          ),
        ),
      ],
    );
  }
}
