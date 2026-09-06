import 'package:flutter/material.dart';

import '../../controllers/auth_controller.dart';
import '../../controllers/player_controller.dart';
import '../../models/music_models.dart';
import '../pages/desktop_lyrics_settings_page.dart';
import '../widgets/audio_effects_sheet.dart';
import '../widgets/desktop_anchored_menu.dart';
import '../widgets/playback_speed_sheet.dart';
import '../widgets/sleep_timer_sheet.dart';
import '../widgets/song_action_sheets.dart';
import '../widgets/toast.dart';
import 'player_controls.dart';

class TopBar extends StatelessWidget {
  const TopBar({
    super.key,
    required this.player,
    required this.auth,
    required this.song,
    required this.onClose,
    required this.onArtistTap,
  });

  final PlayerController player;
  final AuthController auth;
  final Song song;
  final VoidCallback onClose;
  final ValueChanged<Song> onArtistTap;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: auth,
      builder: (context, _) {
        final liked = auth.isLiked(song);
        return Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 16, 6),
          child: Row(
            children: [
              IconButton(
                tooltip: '返回',
                color: Colors.white,
                onPressed: onClose,
                icon: const Icon(Icons.keyboard_arrow_down_rounded),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      song.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    Text(
                      song.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Colors.white.withValues(alpha: .82),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              GlassIconButton(
                tooltip: liked ? '取消喜欢' : '喜欢',
                onPressed: song.source == SongSource.kugou
                    ? () => auth.toggleLike(song)
                    : null,
                icon: liked
                    ? Icons.favorite_rounded
                    : Icons.favorite_border_rounded,
              ),
              const SizedBox(width: 8),
              PlayerAudioQualityPill(player: player),
              const SizedBox(width: 8),
              Builder(
                builder: (moreButtonContext) => GlassIconButton(
                  tooltip: '更多',
                  onPressed: () => _showMoreSheet(moreButtonContext),
                  icon: Icons.more_horiz_rounded,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _showMoreSheet(BuildContext context) {
    showSongActionSheet(
      context: context,
      song: song,
      // PC：锚定到"更多"按钮下方（context 已由调用点传入按钮级 context）。
      anchor: anchorBelow(context),
      actions: [
        // Grid actions
        SongSheetAction(
          icon: Icons.speed_rounded,
          title: '倍速',
          subtitle: player.playbackSpeedLabel,
          isGrid: true,
          onTap: () => showPlaybackSpeedSheet(context: context, player: player),
        ),
        SongSheetAction(
          icon: Icons.high_quality_rounded,
          title: '音质',
          subtitle: player.audioQuality.badge,
          isGrid: true,
          onTap: () => showAudioQualityPicker(context, player),
        ),
        if (player.isAudioEffectsSupported)
          SongSheetAction(
            icon: Icons.graphic_eq_rounded,
            title: '音效',
            isGrid: true,
            onTap: () =>
                showAudioEffectsSheet(context: context, player: player),
          ),
        SongSheetAction(
          icon: Icons.auto_awesome_rounded,
          title: '高潮',
          isGrid: true,
          onTap: () async {
            final ok = await player.playClimaxPreview();
            if (!ok) Toast.error('暂无高潮片段');
          },
        ),
        SongSheetAction(
          icon: Icons.bedtime_rounded,
          title: '定时',
          isGrid: true,
          onTap: () => showSleepTimerSheet(context: context, player: player),
        ),

        if (player.isDesktopLyricsSupported) ...[
          SongSheetAction(
            icon: player.desktopLyricsEnabled
                ? Icons.lyrics_rounded
                : Icons.lyrics_outlined,
            title: '桌面歌词',
            isGrid: true,
            onTap: () async {
              Navigator.of(context).pop();
              await player.setDesktopLyricsEnabled(
                !player.desktopLyricsEnabled,
              );
            },
          ),
          if (player.desktopLyricsEnabled)
            SongSheetAction(
              icon: Icons.tune_rounded,
              title: '歌词设置',
              isGrid: true,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => DesktopLyricsSettingsPage(player: player),
                ),
              ),
            ),
        ],
        SongSheetAction(
          icon: Icons.queue_music_rounded,
          title: '下一首',
          isGrid: true,
          onTap: () => addSongToQueueWithFeedback(
            context: context,
            player: player,
            song: song,
          ),
        ),
        // List actions
        if (song.source == SongSource.kugou)
          SongSheetAction(
            icon: Icons.playlist_add_rounded,
            title: '添加到歌单',
            onTap: () => showAddToPlaylistSheet(
              context: context,
              auth: auth,
              song: song,
            ),
          ),
      ],
    );
  }
}
