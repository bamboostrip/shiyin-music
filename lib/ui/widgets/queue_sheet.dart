import 'package:flutter/material.dart';

import '../../controllers/player_controller.dart';
import '../../models/music_models.dart';
import 'artwork.dart';
import 'toast.dart';

/// 弹出播放队列面板（底部弹层）。
///
/// 从 MiniPlayer 抽取共享：桌面播放栏（desktop_player_bar.dart）复用同一面板，
/// 行为与原有 MiniPlayer 完全一致。
Future<void> showQueueSheet(
  BuildContext context,
  PlayerController player,
) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    builder: (sheetContext) {
      final colorScheme = Theme.of(sheetContext).colorScheme;
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(
                  children: [
                    Text(
                      '播放队列',
                      style: Theme.of(sheetContext)
                          .textTheme
                          .titleLarge
                          ?.copyWith(fontWeight: FontWeight.w900),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '${player.queue.length} 首',
                      style: Theme.of(sheetContext).textTheme.bodyMedium?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                    ),
                    const Spacer(),
                    TextButton(
                      onPressed: player.queue.length > 1
                          ? () => clearQueue(sheetContext, player)
                          : null,
                      child: Text(
                        '清空',
                        style: TextStyle(color: colorScheme.error),
                      ),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: AnimatedBuilder(
                  animation: player,
                  builder: (context, _) {
                    if (player.queue.isEmpty) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 32),
                        child: Center(
                          child: Text(
                            '播放队列为空',
                            style: Theme.of(sheetContext)
                                .textTheme
                                .bodyMedium
                                ?.copyWith(
                                  color: colorScheme.onSurfaceVariant,
                                ),
                          ),
                        ),
                      );
                    }
                    return ListView.separated(
                      shrinkWrap: true,
                      itemCount: player.queue.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 2),
                      itemBuilder: (context, index) {
                        final song = player.queue[index];
                        final active =
                            player.currentSong?.hash == song.hash;
                        return QueueTile(
                          song: song,
                          index: index + 1,
                          active: active,
                          isPlaying: active && player.isPlaying,
                          onTap: () {
                            Navigator.of(sheetContext).pop();
                            player.playSong(song, queue: player.queue);
                          },
                          onDelete: player.queue.length > 1
                              ? () => removeFromQueue(sheetContext, player, index)
                              : null,
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

/// 从队列中移除指定项（保留当前播放歌曲）。
void removeFromQueue(
  BuildContext sheetContext,
  PlayerController player,
  int index,
) {
  final newQueue = List<Song>.of(player.queue);
  if (index < 0 || index >= newQueue.length) return;
  final removed = newQueue.removeAt(index);
  final current = player.currentSong;
  if (current == null) return;

  if (removed.hash == current.hash) {
    // 删除的是当前播放歌曲：切到同位置的新歌
    final nextIndex = index.clamp(0, newQueue.length - 1);
    if (newQueue.isEmpty) {
      Navigator.of(sheetContext).pop();
      player.playSong(current, queue: [current]);
      return;
    }
    Navigator.of(sheetContext).pop();
    player.playSong(newQueue[nextIndex], queue: newQueue);
  } else {
    // 非当前歌曲：仅更新队列，不打断播放
    player.playSong(current, queue: newQueue);
  }
}

/// 清空队列（仅保留当前播放歌曲）。
void clearQueue(BuildContext sheetContext, PlayerController player) {
  final current = player.currentSong;
  if (current == null) return;
  Navigator.of(sheetContext).pop();
  player.playSong(current, queue: [current]);
  Toast.success('已清空播放队列');
}

class QueueTile extends StatelessWidget {
  const QueueTile({
    super.key,
    required this.song,
    required this.index,
    required this.active,
    required this.isPlaying,
    required this.onTap,
    this.onDelete,
  });

  final Song song;
  final int index;
  final bool active;
  final bool isPlaying;
  final VoidCallback onTap;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: active
              ? colorScheme.primary.withValues(alpha: .09)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 24,
              child: Text(
                '$index',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: active
                          ? colorScheme.primary
                          : colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w700,
                    ),
              ),
            ),
            const SizedBox(width: 10),
            Artwork(url: song.coverUrl, size: 40, borderRadius: 8),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    song.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: active ? colorScheme.primary : null,
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    song.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: active
                              ? colorScheme.primary.withValues(alpha: .72)
                              : colorScheme.onSurfaceVariant,
                        ),
                  ),
                ],
              ),
            ),
            if (active)
              Icon(
                isPlaying ? Icons.equalizer_rounded : Icons.pause_rounded,
                size: 18,
                color: colorScheme.primary,
              ),
            if (onDelete != null) ...[
              const SizedBox(width: 4),
              IconButton(
                icon: const Icon(Icons.remove_circle_outline_rounded, size: 20),
                onPressed: onDelete,
                visualDensity: VisualDensity.compact,
                tooltip: '从队列移除',
                color: colorScheme.onSurfaceVariant,
                constraints: const BoxConstraints(),
                padding: EdgeInsets.zero,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
