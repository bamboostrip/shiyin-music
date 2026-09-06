import 'package:flutter/material.dart';

import '../../controllers/auth_controller.dart';
import '../../controllers/player_controller.dart';
import '../../controllers/theme_controller.dart';
import '../../models/music_models.dart';
import '../player/player_route.dart';
import 'artwork.dart';
import 'queue_sheet.dart';

class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key, required this.player, required this.auth});

  final PlayerController player;
  final AuthController auth;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final isLandscape = size.width > size.height;
    // 仅车机模式隐藏（由左侧播放面板替代）；普通横屏仍显示。
    if (isLandscape && ThemeController.instance.carModeEnabled) {
      return const SizedBox.shrink();
    }

    return ExcludeSemantics(
      child: AnimatedBuilder(
        animation: player,
        builder: (context, _) {
          final song = player.currentSong;
          if (song == null) {
            return const SizedBox.shrink();
          }
          return _MiniPlayerContent(
            song: song,
            player: player,
            onTap: () => PlayerPageRoute.open(
              context,
              player: player,
              auth: auth,
            ),
            onShowQueue: () => showQueueSheet(context, player),
          );
        },
      ),
    );
  }
}

class _MiniPlayerContent extends StatelessWidget {
  const _MiniPlayerContent({
    required this.song,
    required this.player,
    required this.onTap,
    required this.onShowQueue,
  });

  final Song song;
  final PlayerController player;
  final VoidCallback onTap;
  final VoidCallback onShowQueue;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF1E2433) : Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isDark
                ? Colors.white.withValues(alpha: .12)
                : colorScheme.outlineVariant.withValues(alpha: .5),
            width: 1,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? .28 : .12),
              blurRadius: 16,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            onTap: onTap,
            child: SizedBox(
              height: 64,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: Column(
                      children: [
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(8, 7, 8, 8),
                            child: Row(
                              children: [
                                Artwork(
                                  url: song.coverUrl,
                                  size: 48,
                                  borderRadius: 6,
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    mainAxisAlignment:
                                        MainAxisAlignment.center,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        song.title,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleSmall
                                            ?.copyWith(
                                              fontWeight: FontWeight.w900,
                                              fontSize: 16,
                                            ),
                                      ),
                                      Text(
                                        song.artist,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall
                                            ?.copyWith(
                                              color: colorScheme
                                                  .onSurfaceVariant,
                                              fontWeight: FontWeight.w600,
                                              fontSize: 14,
                                            ),
                                      ),
                                    ],
                                  ),
                                ),
                                AnimatedBuilder(
                                  animation: player,
                                  builder: (context, _) {
                                    return IconButton(
                                      tooltip: player.isPlaying
                                          ? '暂停'
                                          : '播放',
                                      onPressed: player.isPreparing
                                          ? null
                                          : player.togglePlay,
                                      icon: Icon(
                                        player.isPlaying
                                            ? Icons.pause_rounded
                                            : Icons.play_arrow_rounded,
                                        color: colorScheme.onSurface,
                                        size: 30,
                                      ),
                                    );
                                  },
                                ),
                                IconButton(
                                  tooltip: '播放队列',
                                  onPressed: onShowQueue,
                                  icon: Icon(
                                    Icons.queue_music_rounded,
                                    color: colorScheme.onSurface,
                                    size: 29,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        ValueListenableBuilder<Duration>(
                          valueListenable: player.positionListenable,
                          builder: (context, _, _) {
                            final progress =
                                player.duration.inMilliseconds == 0
                                    ? 0.0
                                    : (player.position.inMilliseconds /
                                            player.duration.inMilliseconds)
                                        .clamp(0.0, 1.0);
                            return Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                LinearProgressIndicator(
                                  value: progress,
                                  minHeight: 2,
                                  color: colorScheme.primary,
                                  backgroundColor:
                                      colorScheme.primary.withValues(
                                    alpha: .12,
                                  ),
                                ),
                                if (player.errorMessage case final message?)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 2),
                                    child: Text(
                                      message,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: colorScheme.error,
                                        fontSize: 10,
                                      ),
                                    ),
                                  ),
                              ],
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
