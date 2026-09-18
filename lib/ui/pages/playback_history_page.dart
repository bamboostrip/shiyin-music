import 'package:flutter/material.dart';

import '../../controllers/auth_controller.dart';
import '../../controllers/player_controller.dart';
import '../../models/music_models.dart';
import '../../services/music_api.dart';
import '../widgets/app_song_row.dart';
import '../widgets/desktop_anchored_menu.dart';
import '../widgets/mini_player.dart';
import '../widgets/song_action_sheets.dart';
import '../widgets/toast.dart';
import '../adaptive_layout.dart';
import '../player/song_tap_handler.dart';
import 'artist_detail_page.dart';

/// 播放历史页面：展示最近播放的歌曲列表，支持点击播放和清空。
class PlaybackHistoryPage extends StatefulWidget {
  const PlaybackHistoryPage({
    super.key,
    required this.api,
    required this.auth,
    required this.player,
  });

  final MusicApi api;
  final AuthController auth;
  final PlayerController player;

  @override
  State<PlaybackHistoryPage> createState() => _PlaybackHistoryPageState();
}

class _PlaybackHistoryPageState extends State<PlaybackHistoryPage> {
  Future<List<Song>>? _future;
  final _limit = 200;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    setState(() {
      _future = widget.player.getPlaybackHistory(limit: _limit);
    });
  }

  Future<void> _confirmClear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('清空播放历史'),
          content: const Text('确定要清空全部播放历史吗？此操作不可恢复。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('清空'),
            ),
          ],
        );
      },
    );
    if (confirmed != true) return;
    await widget.player.clearPlaybackHistory();
    Toast.success('已清空播放历史');
    _reload();
  }

  void _openArtist(Song song) {
    final artist = song.artists.firstWhere(
      (a) => a.name.isNotEmpty,
      orElse: () => const ArtistRef(id: '', name: ''),
    );
    if (artist.name.isEmpty) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ArtistDetailPage(
          api: widget.api,
          auth: widget.auth,
          artist: artist,
          player: widget.player,
        ),
      ),
    );
  }

  void _play(Song song, List<Song> all) {
    if (openPlayerIfSameSong(
      context,
      player: widget.player,
      auth: widget.auth,
      song: song,
    )) {
      return;
    }
    widget.player.playSong(song, queue: List<Song>.of(all));
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      body: AdaptiveContentPadding(
        child: Stack(
          children: [
            FutureBuilder<List<Song>>(
              future: _future,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.hasError) {
                  return CustomScrollView(
                    slivers: [
                      _buildAppBar(context, colorScheme, 0),
                      SliverFillRemaining(
                        hasScrollBody: false,
                        child: _EmptyOrError(
                          icon: Icons.error_outline_rounded,
                          title: '加载失败',
                          message: '${snapshot.error}',
                        ),
                      ),
                    ],
                  );
                }
                final songs = snapshot.data ?? const <Song>[];
                return CustomScrollView(
                  slivers: [
                    _buildAppBar(context, colorScheme, songs.length),
                    if (songs.isEmpty)
                      const SliverFillRemaining(
                        hasScrollBody: false,
                        child: _EmptyOrError(
                          icon: Icons.history_rounded,
                          title: '还没有播放记录',
                          message: '播放过的歌曲会显示在这里',
                        ),
                      )
                    else
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                        sliver: SliverList.separated(
                          itemCount: songs.length,
                          separatorBuilder: (_, _) => const SizedBox(height: 2),
                          itemBuilder: (context, index) {
                            final song = songs[index];
                            return _HistorySongRow(
                              song: song,
                              player: widget.player,
                              onTap: () => _play(song, songs),
                              onAddToPlaylist: () =>
                                  _addSongToPlaylist(song),
                              onViewArtist: () => _openArtist(song),
                            );
                          },
                        ),
                      ),
                  ],
                );
              },
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: bottomInset + 10,
              child: MiniPlayerSlot(player: widget.player, auth: widget.auth),
            ),
          ],
        ),
      ),
    );
  }

  SliverAppBar _buildAppBar(
    BuildContext context,
    ColorScheme colorScheme,
    int count,
  ) {
    return SliverAppBar(
      pinned: true,
      title: const Text(
        '播放历史',
        style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
      ),
      actions: [
        IconButton(
          tooltip: '清空',
          onPressed: count > 0 ? _confirmClear : null,
          icon: const Icon(Icons.delete_sweep_outlined),
        ),
      ],
    );
  }

  Future<void> _addSongToPlaylist(Song song) async {
    await showAddToPlaylistSheet(
      context: context,
      auth: widget.auth,
      song: song,
    );
  }
}

class _HistorySongRow extends StatelessWidget {
  const _HistorySongRow({
    required this.song,
    required this.player,
    required this.onTap,
    required this.onAddToPlaylist,
    required this.onViewArtist,
  });

  final Song song;
  final PlayerController player;
  final VoidCallback onTap;
  final VoidCallback onAddToPlaylist;
  final VoidCallback onViewArtist;

  @override
  Widget build(BuildContext context) {
    // 行视觉与歌单/搜索/歌手页统一见 AppSongRow；这里只组装
    // 更多菜单（下一首/加歌单/看歌手/下载），序号与时长已收敛掉。
    return AppSongRow(
      song: song,
      player: player,
      onTap: onTap,
      trailing: [
        Builder(builder: (moreButtonContext) {
          return AppSongRowMenuButton(
            onPressed: () {
              showSongActionSheet(
                context: moreButtonContext,
                anchor: anchorBelow(moreButtonContext),
                song: song,
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
                    onTap: onAddToPlaylist,
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
                      onTap: () => player.downloadController!.download(
                        song,
                        player.audioQuality,
                      ),
                    ),
                ],
              );
            },
          );
        }),
      ],
    );
  }
}

class _EmptyOrError extends StatelessWidget {
  const _EmptyOrError({
    required this.icon,
    required this.title,
    required this.message,
  });

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 60, 24, 160),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            icon,
            size: 56,
            color: colorScheme.onSurfaceVariant.withValues(alpha: .5),
          ),
          const SizedBox(height: 14),
          Text(
            title,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            message,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
