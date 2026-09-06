import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../../controllers/auth_controller.dart';
import '../../controllers/download_controller.dart';
import '../../controllers/player_controller.dart';
import '../../models/music_models.dart';
import '../pages/comment_page.dart';
import '../widgets/artwork.dart';
import '../widgets/audio_effects_sheet.dart';
import '../widgets/sleep_timer_sheet.dart';
import '../widgets/song_action_sheets.dart';
import '../widgets/toast.dart';
import 'lyric_views.dart';
import 'player_controls.dart';

class PosterPlayerPage extends StatefulWidget {
  const PosterPlayerPage({
    super.key,
    required this.player,
    required this.song,
    required this.onQueue,
    required this.auth,
    required this.onArtistTap,
    this.onLyricTap,
    this.onCoverTap,
    this.onDismiss,
  });

  final PlayerController player;
  final Song song;
  final VoidCallback onQueue;
  final AuthController auth;
  final ValueChanged<Song> onArtistTap;
  final VoidCallback? onLyricTap;
  final VoidCallback? onCoverTap;
  final VoidCallback? onDismiss;

  @override
  State<PosterPlayerPage> createState() => _PosterPlayerPageState();
}

class _PosterPlayerPageState extends State<PosterPlayerPage>
    with AutomaticKeepAliveClientMixin, SingleTickerProviderStateMixin {
  double _dragDownY = 0.0;
  double _dragDistance = 0.0;
  late final AnimationController _resetController;
  late Animation<double> _resetAnimation;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _resetAnimation = const AlwaysStoppedAnimation(0.0);
    _resetController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    )..addListener(() {
        setState(() {
          _dragDistance = _resetAnimation.value;
        });
      });
  }

  @override
  void dispose() {
    _resetController.dispose();
    super.dispose();
  }

  void _onVerticalDragDown(DragDownDetails details) {
    _dragDownY = details.globalPosition.dy;
  }

  void _onVerticalDragStart(DragStartDetails details) {
    if (widget.onDismiss == null) return;
    if (_resetController.isAnimating) {
      _resetController.stop();
    }
    final slop = details.globalPosition.dy - _dragDownY;
    if (slop > 0) {
      setState(() {
        _dragDistance = slop;
      });
    }
  }

  void _onVerticalDragUpdate(DragUpdateDetails details) {
    if (widget.onDismiss == null) return;
    final delta = details.primaryDelta ?? 0.0;
    // 阻尼处理：超过 80 之后位移系数降低
    final factor = _dragDistance > 80.0 ? 0.6 : 1.0;
    final newDistance = math.max(0.0, _dragDistance + delta * factor);
    if (newDistance != _dragDistance) {
      setState(() {
        _dragDistance = newDistance;
      });
    }
  }

  void _onVerticalDragEnd(DragEndDetails details) {
    if (widget.onDismiss == null) return;
    final velocity = details.primaryVelocity ?? 0.0;
    if (_dragDistance > 80.0 || velocity > 800.0) {
      widget.onDismiss?.call();
      _dragDistance = 0.0;
    } else {
      _animateReset();
    }
  }

  void _onVerticalDragCancel() {
    if (widget.onDismiss == null) return;
    if (_dragDistance > 0) {
      _animateReset();
    }
  }

  void _animateReset() {
    _resetAnimation = Tween<double>(
      begin: _dragDistance,
      end: 0.0,
    ).animate(CurvedAnimation(
      parent: _resetController,
      curve: Curves.easeOutCubic,
    ));
    _resetController.forward(from: 0.0);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onVerticalDragDown: widget.onDismiss != null ? _onVerticalDragDown : null,
      onVerticalDragStart:
          widget.onDismiss != null ? _onVerticalDragStart : null,
      onVerticalDragUpdate:
          widget.onDismiss != null ? _onVerticalDragUpdate : null,
      onVerticalDragEnd: widget.onDismiss != null ? _onVerticalDragEnd : null,
      onVerticalDragCancel:
          widget.onDismiss != null ? _onVerticalDragCancel : null,
      child: Transform.translate(
        key: const Key('poster_player_dismiss_transform'),
        offset: Offset(0, _dragDistance),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxHeight < 650;
            final horizontalPadding = compact ? 20.0 : 28.0;

            final maxArtworkHeight =
                (constraints.maxHeight * (compact ? 0.34 : 0.42))
                    .clamp(130.0, 330.0);
            final artworkMaxWidth = math.min(
              constraints.maxWidth - horizontalPadding * 2,
              maxArtworkHeight,
            );

            return Padding(
              padding: EdgeInsets.fromLTRB(
                horizontalPadding,
                compact ? 4 : 8,
                horizontalPadding,
                compact ? 10 : 16,
              ),
              child: Column(
                children: [
                  const Spacer(),
                  ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: artworkMaxWidth),
                    child: AspectRatio(
                      aspectRatio: 1,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () {
                          HapticFeedback.lightImpact();
                          widget.onCoverTap?.call();
                        },
                        child: Hero(
                          tag: 'player_cover',
                          child: Artwork(
                            url: widget.song.coverUrl,
                            size: double.infinity,
                            borderRadius: 8,
                          ),
                        ),
                      ),
                    ),
                  ),
              SizedBox(height: compact ? 12 : 20),
              PosterSongInfoRow(
                song: widget.song,
                player: widget.player,
                auth: widget.auth,
                onArtistTap: widget.onArtistTap,
              ),
              SizedBox(height: compact ? 8 : 14),
              PosterLyricPreview(
                player: widget.player,
                onLyricTap: widget.onLyricTap,
                compact: compact,
              ),
              SizedBox(height: compact ? 8 : 12),
              PosterActionRail(
                player: widget.player,
                song: widget.song,
                auth: widget.auth,
              ),
              const Spacer(),
              Progress(player: widget.player, bright: true),
              SizedBox(height: compact ? 6 : 10),
              Controls(
                player: widget.player,
                bright: true,
                onQueue: widget.onQueue,
              ),
            ],
          ),
        );
      },
    ),
  ),
);
  }
}

class PosterSongInfoRow extends StatelessWidget {
  const PosterSongInfoRow({
    super.key,
    required this.song,
    required this.player,
    required this.auth,
    required this.onArtistTap,
  });

  final Song song;
  final PlayerController player;
  final AuthController auth;
  final ValueChanged<Song> onArtistTap;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                song.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 4),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => onArtistTap(song),
                      child: Text(
                        song.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: Colors.white70,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  PlayerAudioQualityPill(player: player, compact: true),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        ListenableBuilder(
          listenable: auth,
          builder: (context, _) {
            final liked = auth.isLiked(song);
            return SizedBox(
              width: 44,
              height: 44,
              child: IconButton(
                padding: EdgeInsets.zero,
                iconSize: 26,
                tooltip: liked ? '取消喜欢' : '喜欢',
                onPressed: () => auth.toggleLike(song),
                icon: Icon(
                  liked
                      ? Icons.favorite_rounded
                      : Icons.favorite_border_rounded,
                  color: liked
                      ? Colors.redAccent
                      : Colors.white.withValues(alpha: .7),
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}

class PosterActionRail extends StatelessWidget {
  const PosterActionRail({
    super.key,
    required this.player,
    required this.song,
    required this.auth,
  });

  final PlayerController player;
  final Song song;
  final AuthController auth;

  Widget _buildDownloadButton(BuildContext context) {
    DownloadController? downloadCtrl;
    try {
      downloadCtrl = player.downloadController;
    } catch (_) {
      downloadCtrl = null;
    }

    if (downloadCtrl != null) {
      final ctrl = downloadCtrl;
      return ListenableBuilder(
        listenable: ctrl,
        builder: (context, _) {
          final downloaded = ctrl.isDownloaded(song);
          return IconButton(
            iconSize: 24,
            tooltip: downloaded ? '已下载' : '下载',
            icon: Icon(
              downloaded
                  ? Icons.download_done_rounded
                  : Icons.download_rounded,
            ),
            color: downloaded
                ? Theme.of(context).colorScheme.primary
                : Colors.white.withValues(alpha: .85),
            onPressed: () {
              if (downloaded) {
                Toast.info('歌曲已下载');
              } else {
                ctrl.download(song, player.audioQuality);
                Toast.success('已加入下载队列');
              }
            },
          );
        },
      );
    }

    return IconButton(
      iconSize: 24,
      tooltip: '下载',
      icon: const Icon(Icons.download_rounded),
      color: Colors.white.withValues(alpha: .85),
      onPressed: () {
        Toast.info('下载功能未就绪');
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final isKugou = song.source == SongSource.kugou;

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceAround,
      children: [
        // 1. 收藏到歌单
        IconButton(
          iconSize: 24,
          tooltip: '添加到歌单',
          icon: const Icon(Icons.playlist_add_rounded),
          color: Colors.white.withValues(alpha: .85),
          onPressed: () => showAddToPlaylistSheet(
            context: context,
            auth: auth,
            song: song,
          ),
        ),

        // 2. 音效 / 定时
        AnimatedBuilder(
          animation: player,
          builder: (context, _) {
            final hasAudioEffects = player.isAudioEffectsSupported;
            return IconButton(
              iconSize: 24,
              tooltip: hasAudioEffects ? '音效' : '定时播放',
              icon: Icon(
                hasAudioEffects
                    ? Icons.graphic_eq_rounded
                    : Icons.bedtime_rounded,
              ),
              color: Colors.white.withValues(alpha: .85),
              onPressed: () {
                if (hasAudioEffects) {
                  showAudioEffectsSheet(context: context, player: player);
                } else {
                  showSleepTimerSheet(context: context, player: player);
                }
              },
            );
          },
        ),

        // 3. 下载
        _buildDownloadButton(context),

        // 4. 评论
        IconButton(
          iconSize: 24,
          tooltip: isKugou ? '评论' : '暂无评论',
          icon: const Icon(Icons.chat_bubble_outline_rounded),
          color: isKugou
              ? Colors.white.withValues(alpha: .85)
              : Colors.white.withValues(alpha: .24),
          onPressed: isKugou
              ? () {
                  final mixsongid = song.albumAudioId ?? song.id;
                  if (mixsongid.isEmpty) return;
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => CommentPage(
                        api: player.api,
                        mixsongid: mixsongid,
                      ),
                    ),
                  );
                }
              : null,
        ),
      ],
    );
  }
}

int activeLyricIndexFor(List<LyricLine> lyrics, Duration position) {
  if (lyrics.isEmpty) return -1;
  var index = 0;
  for (var i = 0; i < lyrics.length; i++) {
    if (position >= lyrics[i].time) {
      index = i;
    } else {
      break;
    }
  }
  return index;
}

class PosterLyricPreview extends StatefulWidget {
  const PosterLyricPreview({
    super.key,
    required this.player,
    this.onLyricTap,
    this.compact = false,
  });

  final PlayerController player;
  final VoidCallback? onLyricTap;
  final bool compact;

  @override
  State<PosterLyricPreview> createState() => _PosterLyricPreviewState();
}

class _PosterLyricPreviewState extends State<PosterLyricPreview> {
  late final Ticker _ticker;
  Duration _position = Duration.zero;

  @override
  void initState() {
    super.initState();
    _position = widget.player.smoothPosition;
    _ticker = Ticker(_onTick);
    _syncTicker();
  }

  @override
  void didUpdateWidget(covariant PosterLyricPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.player.isScrubbing) {
      _position = widget.player.smoothPosition;
    }
    _syncTicker();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  void _syncTicker() {
    final shouldTick =
        widget.player.isPlaying &&
        widget.player.lyrics.isNotEmpty &&
        !widget.player.isScrubbing;
    if (shouldTick && !_ticker.isActive) {
      _ticker.start();
    } else if (!shouldTick && _ticker.isActive) {
      _ticker.stop();
    }
  }

  void _onTick(Duration elapsed) {
    if (!mounted || widget.player.isScrubbing) {
      return;
    }
    setState(() => _position = widget.player.smoothPosition);
  }

  @override
  Widget build(BuildContext context) {
    final previewHeight = widget.compact ? 56.0 : 72.0;
    final lyrics = widget.player.lyrics;

    if (lyrics.isEmpty) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onLyricTap,
        child: SizedBox(
          height: previewHeight,
          child: Center(
            child: Text(
              widget.player.isPreparing ? '歌词加载中...' : '暂无歌词',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: Colors.white.withValues(alpha: .78),
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      );
    }

    final index = activeLyricIndexFor(lyrics, _position);
    final current = lyrics[index];
    final next = index + 1 < lyrics.length ? lyrics[index + 1] : null;
    final currentStyle = Theme.of(context).textTheme.titleLarge!.copyWith(
      color: Colors.white,
      fontSize: widget.compact ? 18 : 22,
      height: 1.22,
      fontWeight: FontWeight.w900,
    );
    final nextStyle = Theme.of(context).textTheme.titleMedium!.copyWith(
      color: Colors.white.withValues(alpha: .46),
      fontSize: widget.compact ? 13 : 15,
      height: 1.18,
      fontWeight: FontWeight.w700,
    );

    // 歌词预览每帧更新位置，用 ExcludeSemantics 防止 Windows AXTree 竞态崩溃
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onLyricTap,
      child: ExcludeSemantics(
        child: SizedBox(
          height: previewHeight,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 260),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeOutCubic,
            child: Column(
              key: ValueKey(current.time.inMilliseconds),
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SizedBox(
                  height: widget.compact ? 28 : 34,
                  child: MarqueeSingleLine(
                    textKey: current.time.inMilliseconds,
                    child: LyricText(
                      line: current,
                      active: true,
                      position: _position,
                      styleOverride: currentStyle,
                      textAlign: TextAlign.center,
                      singleLine: true,
                    ),
                  ),
                ),
                SizedBox(height: widget.compact ? 4 : 6),
                SizedBox(
                  height: widget.compact ? 20 : 24,
                  child: MarqueeSingleLine(
                    textKey:
                        current.translation != null &&
                                current.translation!.isNotEmpty
                            ? current.time.inMilliseconds
                            : (next?.time.inMilliseconds ?? -1),
                    child: Text(
                      current.translation != null &&
                              current.translation!.isNotEmpty
                          ? current.translation!
                          : (next?.text ?? ''),
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.visible,
                      style: nextStyle,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class MarqueeSingleLine extends StatefulWidget {
  const MarqueeSingleLine({
    super.key,
    required this.child,
    required this.textKey,
  });

  final Widget child;
  final Object textKey;

  @override
  State<MarqueeSingleLine> createState() => _MarqueeSingleLineState();
}

class _MarqueeSingleLineState extends State<MarqueeSingleLine>
    with SingleTickerProviderStateMixin {
  final _viewportKey = GlobalKey();
  final _contentKey = GlobalKey();
  late final AnimationController _controller;
  double _overflow = 0;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
  }

  @override
  void didUpdateWidget(covariant MarqueeSingleLine oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.textKey != widget.textKey) {
      _controller
        ..stop()
        ..reset();
      _overflow = 0;
      WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _measure() {
    if (!mounted) {
      return;
    }
    final viewport = _viewportKey.currentContext?.size?.width ?? 0;
    final content = _contentKey.currentContext?.size?.width ?? 0;
    final overflow = math.max(0.0, content - viewport);
    if ((overflow - _overflow).abs() < 1) {
      return;
    }
    setState(() => _overflow = overflow);
    if (overflow > 0) {
      _controller
        ..duration = Duration(milliseconds: (overflow * 42).round() + 2600)
        ..repeat(reverse: true);
    } else {
      _controller
        ..stop()
        ..reset();
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return ClipRect(
          key: _viewportKey,
          child: SizedBox(
            width: constraints.maxWidth,
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, child) {
                final offset = _overflow <= 0
                    ? 0.0
                    : -_overflow * _controller.value;
                return Align(
                  alignment: _overflow <= 0
                      ? Alignment.center
                      : Alignment.centerLeft,
                  child: Transform.translate(
                    offset: Offset(offset, 0),
                    child: child,
                  ),
                );
              },
              child: OverflowBox(
                minWidth: 0,
                maxWidth: double.infinity,
                alignment: Alignment.centerLeft,
                child: RepaintBoundary(key: _contentKey, child: widget.child),
              ),
            ),
          ),
        );
      },
    );
  }
}
