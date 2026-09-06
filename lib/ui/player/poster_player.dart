import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../controllers/player_controller.dart';
import '../../models/music_models.dart';
import '../pages/comment_page.dart';
import '../widgets/artwork.dart';
import 'lyric_views.dart';
import 'player_controls.dart';

class PosterPlayerPage extends StatefulWidget {
  const PosterPlayerPage({
    super.key,
    required this.player,
    required this.song,
    required this.onQueue,
  });

  final PlayerController player;
  final Song song;
  final VoidCallback onQueue;

  @override
  State<PosterPlayerPage> createState() => _PosterPlayerPageState();
}

class _PosterPlayerPageState extends State<PosterPlayerPage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxHeight < 620;
        final artworkMaxWidth = compact ? 250.0 : 330.0;

        return Padding(
          padding: const EdgeInsets.fromLTRB(28, 12, 28, 18),
          child: Column(
            children: [
              const Spacer(),
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: artworkMaxWidth),
                child: AspectRatio(
                  aspectRatio: 1,
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
              SizedBox(height: compact ? 14 : 26),
              PosterLyricPreview(player: widget.player),
              if (!compact) const SizedBox(height: 4),
              CommentEntry(player: widget.player, song: widget.song),
              const Spacer(),
              Progress(player: widget.player, bright: true),
              const SizedBox(height: 10),
              Controls(
                player: widget.player,
                bright: true,
                onQueue: widget.onQueue,
              ),
            ],
          ),
        );
      },
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
  const PosterLyricPreview({super.key, required this.player});

  final PlayerController player;

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
    final lyrics = widget.player.lyrics;
    if (lyrics.isEmpty) {
      return SizedBox(
        height: 104,
        child: Center(
          child: Text(
            widget.player.isPreparing ? '歌词加载中...' : '暂无歌词',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              color: Colors.white.withValues(alpha: .78),
              fontWeight: FontWeight.w800,
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
      fontSize: 22,
      height: 1.22,
      fontWeight: FontWeight.w900,
    );
    final nextStyle = Theme.of(context).textTheme.titleMedium!.copyWith(
      color: Colors.white.withValues(alpha: .46),
      height: 1.18,
      fontWeight: FontWeight.w700,
    );

    // 歌词预览每帧更新位置，用 ExcludeSemantics 防止 Windows AXTree 竞态崩溃
    return ExcludeSemantics(
      child: SizedBox(
        height: 96,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 260),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeOutCubic,
          child: Column(
            key: ValueKey(current.time.inMilliseconds),
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(
                height: 36,
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
              const SizedBox(height: 8),
              SizedBox(
                height: 25,
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

class CommentEntry extends StatelessWidget {
  const CommentEntry({super.key, required this.player, required this.song});

  final PlayerController player;
  final Song song;

  @override
  Widget build(BuildContext context) {
    // 其他平台歌曲不支持评论
    if (song.source != SongSource.kugou) {
      return const SizedBox.shrink();
    }
    return Align(
      alignment: Alignment.centerLeft,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () {
            final mixsongid = song.albumAudioId ?? song.id;
            if (mixsongid.isEmpty) return;
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) =>
                    CommentPage(api: player.api, mixsongid: mixsongid),
              ),
            );
          },
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Icon(
              Icons.comment_outlined,
              size: 20,
              color: Colors.white54,
            ),
          ),
        ),
      ),
    );
  }
}
