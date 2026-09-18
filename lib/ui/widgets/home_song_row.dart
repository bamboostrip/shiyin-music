import 'package:flutter/material.dart';

import '../../controllers/auth_controller.dart';
import '../../controllers/player_controller.dart';
import '../../models/music_models.dart';
import '../form_factor.dart';
import 'artwork.dart';
import 'cover_play_overlay.dart';
import 'desktop_anchored_menu.dart';
import 'marquee_text.dart';
import 'now_playing_badge.dart';
import 'song_action_sheets.dart';

/// 首页歌曲行。
///
/// 行语义与 PC 表格统一：桌面端单击不触发播放（选中态省略）、双击播放；
/// 封面在 hover 时浮现居中播放按钮，单击播放按钮直接播放；
/// 移动端/车机端保持单击即播，行为逐字节不变。
class HomeSongRow extends StatefulWidget {
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

  @override
  State<HomeSongRow> createState() => _HomeSongRowState();
}

class _HomeSongRowState extends State<HomeSongRow> {
  bool _hovered = false;

  /// 弹出歌曲操作菜单（PC 与移动端共用条目）。
  ///
  /// [anchor] 为空走移动端底部弹窗；非空（PC `...` 按钮下方或行右键位置）
  /// 锚定为桌面上下文菜单。
  void _showActionMenu(BuildContext context, {Offset? anchor}) {
    showSongActionSheet(
      context: context,
      song: widget.song,
      anchor: anchor,
      actions: [
        SongSheetAction(
          icon: Icons.queue_music_rounded,
          title: '下一首播放',
          onTap: () => addSongToQueueWithFeedback(
            context: context,
            player: widget.player,
            song: widget.song,
          ),
        ),
        SongSheetAction(
          icon: Icons.playlist_add_rounded,
          title: '添加到歌单',
          onTap: () => showAddToPlaylistSheet(
            context: context,
            auth: widget.auth,
            song: widget.song,
          ),
        ),
        SongSheetAction(
          icon: Icons.person_rounded,
          title: '查看歌手',
          onTap: widget.onViewArtist,
        ),
        if (widget.player.downloadController != null)
          SongSheetAction(
            icon: widget.player.downloadController!.isDownloaded(widget.song)
                ? Icons.download_done_rounded
                : Icons.download_rounded,
            title: widget.player.downloadController!.isDownloaded(widget.song)
                ? '已下载'
                : '下载',
            onTap: () => widget.player.downloadController!
                .download(widget.song, widget.player.audioQuality),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDesktop = isDesktopFormFactor;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // 桌面端使用更克制紧凑的 8px 圆角与 44px 封面，移动端使用 12px 与 48px
    final rowRadius = BorderRadius.circular(isDesktop ? 8 : 12);
    final coverRadius = isDesktop ? 6.0 : 8.0;
    final coverSize = isDesktop ? 44.0 : 48.0;

    // 主页歌曲行响应 player 重建（播放进度/状态），高频更新会触发
    // Windows AXTree 竞态崩溃，仅桌面平台排除语义树；移动端保留无障碍
    return ExcludeSemantics(
      excluding: isDesktopPlatform,
      child: AnimatedBuilder(
        animation: widget.player,
        builder: (context, _) {
          final active = widget.song.hash.isNotEmpty &&
              widget.player.currentSong?.hash == widget.song.hash;
          final activeColor = colorScheme.primary;

          final hoverBg = isDark
              ? Colors.white.withValues(alpha: 0.07)
              : colorScheme.surfaceContainerHigh.withValues(alpha: 0.7);

          // 正在播放：仅桌面与表格行同口径加强整行底色 + 描边，避免密集
          // 列表里“看不清在播哪一首”；移动端/车机保持透明，不整行染色。
          final rowBg = active && isDesktop
              ? activeColor.withValues(alpha: 0.10)
              : (isDesktop && _hovered ? hoverBg : Colors.transparent);

          // 指针约定：桌面双击播放 → 整行默认箭头（封面播放键/收藏钮各自
          // 覆盖为手型）；移动端形态单击播放 → 手型（触屏无光标，不受影响）。
          return MouseRegion(
            cursor: isDesktop
                ? SystemMouseCursors.basic
                : SystemMouseCursors.click,
            onEnter: isDesktop ? (_) => setState(() => _hovered = true) : null,
            onExit: isDesktop ? (_) => setState(() => _hovered = false) : null,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: isDesktop
                  ? null
                  : () => widget.onPlay(widget.song, widget.queue),
              onDoubleTap: isDesktop
                  ? () => widget.onPlay(widget.song, widget.queue)
                  : null,
              onSecondaryTapDown: isDesktop
                  ? (details) => _showActionMenu(
                        context,
                        anchor: details.globalPosition,
                      )
                  : null,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 140),
                padding: EdgeInsets.symmetric(
                  vertical: isDesktop ? 5 : 6,
                  horizontal: 8,
                ),
                decoration: BoxDecoration(
                  color: rowBg,
                  borderRadius: rowRadius,
                ),
                // 描边画在 foregroundDecoration：不参与布局，行高保持
                // 48 封面 + 上下 padding（车机网格按 60/行预留高度，见
                // home_page.dart 的 rowCount * 60.0），否则每行 +2px 会溢出。
                foregroundDecoration: BoxDecoration(
                  borderRadius: rowRadius,
                  border: Border.all(
                    color: active && isDesktop
                        ? activeColor.withValues(alpha: 0.28)
                        : Colors.transparent,
                    width: 1,
                  ),
                ),
                child: Row(
                  children: [
                    Stack(
                      children: [
                        CoverPlayOverlay(
                          enabled: isDesktop,
                          isHovered: _hovered,
                          isCurrent: active,
                          isPlaying: active && widget.player.isPlaying,
                          onPause: () => widget.player.togglePlay(),
                          onResume: () => widget.player.togglePlay(),
                          borderRadius: coverRadius,
                          buttonSize: isDesktop ? 28 : 32,
                          iconSize: isDesktop ? 18 : 22,
                          buttonColor: Colors.black54,
                          iconColor: Colors.white,
                          onPlay: () =>
                              widget.onPlay(widget.song, widget.queue),
                          cover: Artwork(
                            url: widget.song.coverUrl,
                            size: coverSize,
                            borderRadius: coverRadius,
                          ),
                        ),
                        if (active && !isDesktop)
                          Positioned(
                            right: 3,
                            bottom: 3,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: Theme.of(context)
                                    .colorScheme
                                    .surface
                                    .withValues(alpha: .88),
                                borderRadius: BorderRadius.circular(5),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.all(2),
                                child: NowPlayingBadge(
                                  active: active,
                                  playing: widget.player.isPlaying,
                                  color: activeColor,
                                  size: isDesktop ? 12 : 13,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // 长歌名不再被 ellipsis 截断；放得下时 MarqueeText
                          // 内部零开销地退化为静态文本。
                          MarqueeText.text(
                            widget.song.title,
                            style: Theme.of(context)
                                .textTheme
                                .titleSmall
                                ?.copyWith(
                                  color: active ? activeColor : null,
                                  fontWeight: FontWeight.w600,
                                  fontSize: isDesktop ? 14 : 15,
                                ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            widget.song.artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context)
                                .textTheme
                                .bodyMedium
                                ?.copyWith(
                                  color: active
                                      ? activeColor.withValues(alpha: .72)
                                      : colorScheme.onSurfaceVariant,
                                  fontWeight: FontWeight.w400,
                                  fontSize: isDesktop ? 12 : 12.5,
                                ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 6),
                    IconButton(
                      // 单击动作 → 手型（IconButton 默认在桌面原生解析为箭头）。
                      mouseCursor: SystemMouseCursors.click,
                      onPressed: widget.onLikeTap,
                      icon: Icon(
                        widget.isLiked
                            ? Icons.favorite_rounded
                            : Icons.favorite_border_rounded,
                        color: widget.isLiked
                            ? Colors.redAccent
                            : colorScheme.outline,
                        size: isDesktop ? 20 : 22,
                      ),
                      visualDensity: VisualDensity.compact,
                    ),
                    Builder(
                      builder: (moreButtonContext) {
                        return IconButton(
                          tooltip: '更多',
                          mouseCursor: SystemMouseCursors.click,
                          onPressed: () => _showActionMenu(
                            moreButtonContext,
                            anchor: anchorBelow(moreButtonContext),
                          ),
                          icon: const Icon(Icons.more_horiz_rounded),
                          iconSize: isDesktop ? 18 : 20,
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
