import 'package:flutter/material.dart';

import '../../controllers/auth_controller.dart';
import '../../controllers/player_controller.dart';
import '../../models/music_models.dart';
import '../form_factor.dart';
import 'artwork.dart';
import 'desktop_anchored_menu.dart';
import 'hover_row.dart';
import 'now_playing_badge.dart';
import 'song_action_sheets.dart';

/// 首页歌曲行。
///
/// 行语义与 PC 表格统一：桌面端单击不触发播放（选中态省略）、双击播放；
/// 移动端/车机端保持单击即播，行为逐字节不变。
class HomeSongRow extends StatelessWidget {
  const HomeSongRow({
    super.key,
    required this.song,
    required this.queue,
    required this.onPlay,
    required this.isLiked,
    required this.onLikeTap,
    required this.auth,
    required this.player,
    required this.onViewArtist,
  });

  final Song song;
  final List<Song> queue;
  final void Function(Song song, List<Song> queue) onPlay;
  final bool isLiked;
  final VoidCallback onLikeTap;
  final AuthController auth;
  final PlayerController player;
  final VoidCallback onViewArtist;

  /// 弹出歌曲操作菜单（PC 与移动端共用条目）。
  ///
  /// [anchor] 为空走移动端底部弹窗；非空（PC `...` 按钮下方或行右键位置）
  /// 锚定为桌面上下文菜单。
  void _showActionMenu(BuildContext context, {Offset? anchor}) {
    showSongActionSheet(
      context: context,
      song: song,
      anchor: anchor,
      actions: [
        SongSheetAction(
          icon: Icons.queue_music_rounded,
          title: '下一首播放',
          onTap: () => addSongToQueueWithFeedback(
            context: context,
            player: player,
            song: song,
          ),
        ),
        SongSheetAction(
          icon: Icons.playlist_add_rounded,
          title: '添加到歌单',
          onTap: () => showAddToPlaylistSheet(
            context: context,
            auth: auth,
            song: song,
          ),
        ),
        SongSheetAction(
          icon: Icons.person_rounded,
          title: '查看歌手',
          onTap: onViewArtist,
        ),
        if (player.downloadController != null)
          SongSheetAction(
            icon: player.downloadController!.isDownloaded(song)
                ? Icons.download_done_rounded
                : Icons.download_rounded,
            title: player.downloadController!.isDownloaded(song)
                ? '已下载'
                : '下载',
            onTap: () => player.downloadController!
                .download(song, player.audioQuality),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDesktop = isDesktopFormFactor;

    // 主页歌曲行响应 player 重建（播放进度/状态），高频更新会触发
    // Windows AXTree 竞态崩溃，仅桌面平台排除语义树；移动端保留无障碍
    return ExcludeSemantics(
      excluding: isDesktopPlatform,
      child: AnimatedBuilder(
        animation: player,
        builder: (context, _) {
          final active =
              song.hash.isNotEmpty && player.currentSong?.hash == song.hash;
          final activeColor = colorScheme.primary;
          return HoverRow(
            hoverColor: colorScheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(14),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              // 桌面端：单击不播（双击播放）；移动端/车机端：单击即播。
              onTap: isDesktop ? null : () => onPlay(song, queue),
              onDoubleTap: isDesktop ? () => onPlay(song, queue) : null,
              // PC 右键：与 `...` 按钮同一份菜单，锚定到点击处
              //（搜索结果/歌单等表格行已支持，首页行对齐）。
              onSecondaryTapDown: isDesktop
                  ? (details) =>
                      _showActionMenu(context, anchor: details.globalPosition)
                  : null,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 8),
                decoration: BoxDecoration(
                  color: Colors.transparent,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                  children: [
                    Stack(
                      children: [
                        Artwork(url: song.coverUrl, size: 58, borderRadius: 8),
                        if (active)
                          Positioned(
                            right: 5,
                            bottom: 5,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: Theme.of(
                                  context,
                                ).colorScheme.surface.withValues(alpha: .88),
                                borderRadius: BorderRadius.circular(7),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.all(3),
                                child: NowPlayingBadge(
                                  active: active,
                                  playing: player.isPlaying,
                                  color: activeColor,
                                  size: 14,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            song.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleSmall
                                ?.copyWith(
                                  color: active ? activeColor : null,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 16,
                                ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            song.artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(
                                  color: active
                                      ? activeColor.withValues(alpha: .72)
                                      : colorScheme.onSurfaceVariant,
                                  fontWeight: FontWeight.w500,
                                ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    IconButton(
                      onPressed: onLikeTap,
                      icon: Icon(
                        isLiked
                            ? Icons.favorite_rounded
                            : Icons.favorite_border_rounded,
                        color: isLiked ? Colors.redAccent : colorScheme.outline,
                        size: 27,
                      ),
                      visualDensity: VisualDensity.compact,
                    ),
                    Builder(
                      builder: (moreButtonContext) {
                        return IconButton(
                          tooltip: '更多',
                          onPressed: () => _showActionMenu(
                            moreButtonContext,
                            anchor: anchorBelow(moreButtonContext),
                          ),
                          icon: const Icon(Icons.more_horiz_rounded),
                          visualDensity: VisualDensity.compact,
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
