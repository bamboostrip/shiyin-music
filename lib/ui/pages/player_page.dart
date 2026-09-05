import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_lyric/flutter_lyric.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../controllers/auth_controller.dart';
import '../../controllers/player_controller.dart';
import '../../controllers/theme_controller.dart';
import '../../models/music_models.dart';
import '../../services/lyric_converter.dart';
import '../widgets/audio_effects_sheet.dart';
import '../widgets/audio_quality_sheet.dart';
import '../widgets/artwork.dart';
import '../widgets/climax_slider_track.dart';
import '../widgets/desktop_anchored_menu.dart';
import '../widgets/horizontal_wheel_scroll.dart';
import '../form_factor.dart';
import '../widgets/playback_speed_sheet.dart';
import '../widgets/sleep_timer_sheet.dart';
import '../widgets/song_action_sheets.dart';
import '../widgets/toast.dart';
import 'artist_detail_page.dart';
import 'comment_page.dart';
import 'desktop_lyrics_settings_page.dart';

class PlayerPage extends StatefulWidget {
  const PlayerPage({super.key, required this.player, required this.auth});

  final PlayerController player;
  final AuthController auth;

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  static const _screenChannel = MethodChannel('kgka_music_hl/screen');

  @override
  void initState() {
    super.initState();
    unawaited(_setKeepScreenOn(true));
    // 不在此处调用 setPreferredOrientations：方向策略由 ThemeController 全局管理。
    // 如果这里解锁方向，即使用户在设置里没开横屏模式，旋转手机时播放页也会
    // 跟着旋转，影响竖屏体验。
  }

  @override
  void dispose() {
    unawaited(_setKeepScreenOn(false));
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  Future<void> _setKeepScreenOn(bool enabled) async {
    try {
      await _screenChannel.invokeMethod<void>('setKeepScreenOn', enabled);
    } on MissingPluginException {
      // Non-Android targets can ignore this page-level screen setting.
    } on PlatformException {
      // Keeping playback usable is more important than failing the page open.
    }
  }

  @override
  Widget build(BuildContext context) {
    // 整页排除语义树：Windows 桌面 pop 动画期间 AnimatedBuilder 仍会
    // 响应 player notifyListeners 重建子树，导致 AXTree 竞态原生崩溃。
    return ExcludeSemantics(
      child: AnimatedBuilder(
        animation: widget.player,
        builder: (context, _) {
          final song = widget.player.currentSong;
          if (song == null) {
            // 防御性空态：正常情况下底栏无歌时不会进播放页，
            // 万一被外部路由直接打开，也不展示纯空白页。
            final colorScheme = Theme.of(context).colorScheme;
            return Scaffold(
              backgroundColor: colorScheme.surface,
              appBar: AppBar(
                leading: IconButton(
                  tooltip: '返回',
                  icon: const Icon(Icons.keyboard_arrow_down_rounded),
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
                backgroundColor: Colors.transparent,
                elevation: 0,
              ),
              body: Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 84,
                        height: 84,
                        decoration: BoxDecoration(
                          color: colorScheme.primary.withValues(alpha: .10),
                          borderRadius: BorderRadius.circular(24),
                        ),
                        child: Icon(
                          Icons.music_note_rounded,
                          size: 40,
                          color: colorScheme.primary,
                        ),
                      ),
                      const SizedBox(height: 20),
                      Text(
                        '还没有正在播放的歌曲',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.w900,
                            ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '先去挑选一首喜欢的歌曲吧',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                            ),
                      ),
                      const SizedBox(height: 24),
                      FilledButton.tonal(
                        onPressed: () => Navigator.of(context).maybePop(),
                        child: const Text('返回'),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }

          return _PlayerBody(
            player: widget.player,
            auth: widget.auth,
            song: song,
            onClose: () => Navigator.of(context).pop(),
            onQueue: () => _showQueue(context),
          );
        },
      ),
    );
  }

  void _showQueue(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (context) {
        return AnimatedBuilder(
          animation: widget.player,
          builder: (context, _) {
            return ListView.builder(
              itemCount: widget.player.queue.length,
              itemBuilder: (context, index) {
                final song = widget.player.queue[index];
                final active = widget.player.currentSong?.hash == song.hash;
                return ListTile(
                  selected: active,
                  leading: Artwork(url: song.coverUrl, size: 44),
                  title: Text(
                    song.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    song.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () {
                    Navigator.of(context).pop();
                    widget.player.playSong(song, queue: widget.player.queue);
                  },
                );
              },
            );
          },
        );
      },
    );
  }
}

class _PlayerBody extends StatefulWidget {
  const _PlayerBody({
    required this.player,
    required this.auth,
    required this.song,
    required this.onClose,
    required this.onQueue,
  });

  final PlayerController player;
  final AuthController auth;
  final Song song;
  final VoidCallback onClose;
  final VoidCallback onQueue;

  @override
  State<_PlayerBody> createState() => _PlayerBodyState();
}

Future<void> _showAudioQualityPicker(
  BuildContext context,
  PlayerController player, {
  Offset? anchor,
}) async {
  final quality = await showAudioQualitySheet(
    context: context,
    selected: player.audioQuality,
    title: '切换音质',
    subtitle: '会重新加载当前歌曲并尽量保持播放进度',
    anchor: anchor,
  );
  if (quality == null) {
    return;
  }

  await player.setAudioQuality(quality, reloadCurrent: true);
  Toast.success('已切换到 ${quality.label}');
}

class _PlayerBodyState extends State<_PlayerBody> {
  final _pageController = PageController();
  var _page = 0;
  var _pageScrolling = false;
  var _lyricFocusRequest = 0;
  bool? _lastSystemUiLandscape;

  bool get _lyricPageActive => _page == 1 && !_pageScrolling;
  bool get _lyricPageVisible => _page == 1 || _pageScrolling;

  @override
  void dispose() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    if (size.height < 150 || size.width < 150) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: SizedBox.shrink(),
      );
    }
    final landscape = size.width > size.height;
    _syncSystemUi(landscape);
    // PC 桌面端（宽屏）与开启车机模式的横屏场景，均采用双拼分栏大屏布局（左侧封面/操作，右侧全高度歌词面板）
    final useSplitLayout = isDesktopFormFactor ||
        (landscape && ThemeController.instance.carModeEnabled);

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): widget.onClose,
      },
      child: Focus(
        autofocus: true,
        child: AnnotatedRegion<SystemUiOverlayStyle>(
          value: const SystemUiOverlayStyle(
            statusBarIconBrightness: Brightness.light,
            statusBarBrightness: Brightness.light,
          ),
          child: Scaffold(
            backgroundColor: Colors.black,
            body: Stack(
              children: [
                _ArtworkBackground(song: widget.song),
                SafeArea(
                  // 横屏时同样需要处理顶部状态栏和底部系统导航栏（如车机空调控制栏）的遮挡。
                  // 竖屏已由外层 Scaffold 处理，这里对所有方向统一保留 SafeArea。
                  child: Column(
                    children: [
                      if (!useSplitLayout)
                        _TopBar(
                          player: widget.player,
                          auth: widget.auth,
                          song: widget.song,
                          onClose: widget.onClose,
                          onArtistTap: _openArtist,
                        ),
                      Expanded(
                        child: useSplitLayout
                            ? ExcludeSemantics(
                                child: _LandscapePlayerContent(
                                  player: widget.player,
                                  auth: widget.auth,
                                  song: widget.song,
                                  onClose: widget.onClose,
                                  onQueue: widget.onQueue,
                                  onArtistTap: _openArtist,
                                ),
                              )
                            : HorizontalWheelPageScroll(
                                controller: _pageController,
                                child: NotificationListener<ScrollNotification>(
                                  onNotification: _handlePageScrollNotification,
                                  child: PageView(
                                    controller: _pageController,
                                    allowImplicitScrolling: true,
                                    onPageChanged: (value) =>
                                        _setPageState(page: value),
                                    children: [
                                      _PosterPlayerPage(
                                        key: const PageStorageKey(
                                          'poster-player-page',
                                        ),
                                        player: widget.player,
                                        song: widget.song,
                                        onQueue: widget.onQueue,
                                      ),
                                      _LyricPlayerPage(
                                        key: const PageStorageKey(
                                          'lyric-player-page',
                                        ),
                                        player: widget.player,
                                        song: widget.song,
                                        focusRequest: _lyricFocusRequest,
                                        isPageActive: _lyricPageActive,
                                        isPageVisible: _lyricPageVisible,
                                        isPageTransitioning: _pageScrolling,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                      ),
                      if (!useSplitLayout) _PageDots(page: _page),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _syncSystemUi(bool landscape) {
    if (_lastSystemUiLandscape == landscape) {
      return;
    }
    _lastSystemUiLandscape = landscape;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    });
  }

  bool _handlePageScrollNotification(ScrollNotification notification) {
    if (notification.metrics.axis != Axis.horizontal) {
      return false;
    }

    if (notification is ScrollStartNotification) {
      _setPageState(scrolling: true);
    } else if (notification is ScrollEndNotification) {
      final page = (_pageController.page ?? _page.toDouble()).round().clamp(
        0,
        1,
      );
      _setPageState(page: page, scrolling: false);
    }
    return false;
  }

  void _setPageState({int? page, bool? scrolling}) {
    final wasLyricActive = _lyricPageActive;
    final nextPage = page ?? _page;
    final nextScrolling = scrolling ?? _pageScrolling;

    if (nextPage == _page && nextScrolling == _pageScrolling) {
      return;
    }

    setState(() {
      _page = nextPage;
      _pageScrolling = nextScrolling;
      final nextLyricActive = _page == 1 && !_pageScrolling;
      if (!wasLyricActive && nextLyricActive) {
        _lyricFocusRequest++;
      }
    });
  }

  Future<void> _openArtist(Song song) async {
    if (song.source != SongSource.kugou) {
      Toast.info('其他平台歌曲暂不支持查看歌手');
      return;
    }
    final artists = song.artists;
    if (artists.isEmpty) {
      Toast.info('暂无歌手详情');
      return;
    }

    ArtistRef? selected;
    if (artists.length == 1) {
      selected = artists.first;
    } else {
      selected = await showModalBottomSheet<ArtistRef>(
        context: context,
        showDragHandle: true,
        backgroundColor: Theme.of(context).colorScheme.surface,
        builder: (context) {
          return SafeArea(
            child: ListView.separated(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              itemCount: artists.length,
              separatorBuilder: (_, _) => const SizedBox(height: 4),
              itemBuilder: (context, index) {
                final artist = artists[index];
                return ListTile(
                  leading: CircleAvatar(
                    backgroundImage: artist.avatarUrl == null
                        ? null
                        : ResizeImage(
                            NetworkImage(artist.avatarUrl!),
                            width: 80,
                            height: 80,
                          ),
                    child: artist.avatarUrl == null
                        ? const Icon(Icons.person_rounded)
                        : null,
                  ),
                  title: Text(artist.name),
                  onTap: () => Navigator.of(context).pop(artist),
                );
              },
            ),
          );
        },
      );
    }

    if (selected == null || !mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ArtistDetailPage(
          api: widget.player.api,
          auth: widget.auth,
          artist: selected!,
          player: widget.player,
        ),
      ),
    );
  }
}

enum _LyricDisplayMode {
  lyricsWithTranslation,
  lyricsOnly,
  lyricsWithRomanization,
}

List<_LyricDisplayMode> _availableLyricDisplayModes(List<LyricLine> lyrics) {
  if (lyrics.isEmpty) {
    return const [];
  }

  final modes = <_LyricDisplayMode>[];
  final hasTranslation = lyrics.any(
    (line) => line.translation != null && line.translation!.isNotEmpty,
  );
  final hasRomanization = lyrics.any(
    (line) => line.romanization != null && line.romanization!.isNotEmpty,
  );

  if (hasTranslation) {
    modes.add(_LyricDisplayMode.lyricsWithTranslation);
  }
  modes.add(_LyricDisplayMode.lyricsOnly);
  if (hasRomanization) {
    modes.add(_LyricDisplayMode.lyricsWithRomanization);
  }
  return modes;
}

String _lyricDisplayModeLabel(_LyricDisplayMode mode) {
  return switch (mode) {
    _LyricDisplayMode.lyricsWithTranslation => '歌词 + 翻译',
    _LyricDisplayMode.lyricsWithRomanization => '歌词 + 音译',
    _LyricDisplayMode.lyricsOnly => '仅歌词',
  };
}

class _ArtworkBackground extends StatefulWidget {
  const _ArtworkBackground({required this.song});

  final Song song;

  @override
  State<_ArtworkBackground> createState() => _ArtworkBackgroundState();
}

class _ArtworkBackgroundState extends State<_ArtworkBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _rotationController;

  @override
  void initState() {
    super.initState();
    _rotationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 40), // 40 seconds for a full rotation
    )..repeat();
  }

  @override
  void dispose() {
    _rotationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final coverUrl = widget.song.coverUrl;
    final size = MediaQuery.sizeOf(context);
    final maxDim = math.max(size.width, size.height);
    final squareSize = maxDim * 1.2;

    // 旋转动画背景是纯装饰性的，排除语义树防止 Windows AXTree 竞态崩溃
    return ExcludeSemantics(
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 始终显示渐变兜底背景，避免封面加载期间出现纯黑背景
          const _FallbackBackground(),
          if (coverUrl != null)
            OverflowBox(
              maxWidth: squareSize,
              maxHeight: squareSize,
              minWidth: squareSize,
              minHeight: squareSize,
              child: ImageFiltered(
                imageFilter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                child: RotationTransition(
                  turns: _rotationController,
                  child: Image.network(
                    coverUrl,
                    fit: BoxFit.cover,
                    cacheWidth: 100,
                    cacheHeight: 100,
                    errorBuilder: (context, error, stackTrace) =>
                        const SizedBox.shrink(),
                  ),
                ),
              ),
            ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withValues(alpha: .32),
                  Colors.black.withValues(alpha: .56),
                  Colors.black.withValues(alpha: .82),
                ],
              ),
            ),
          ),
          ColoredBox(color: Colors.black.withValues(alpha: .12)),
        ],
      ),
    );
  }
}

class _FallbackBackground extends StatelessWidget {
  const _FallbackBackground();

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF153D35), Color(0xFF061219), Color(0xFF2C1320)],
        ),
      ),
    );
  }
}

class _LandscapePlayerContent extends StatelessWidget {
  const _LandscapePlayerContent({
    required this.player,
    required this.auth,
    required this.song,
    required this.onClose,
    required this.onQueue,
    required this.onArtistTap,
  });

  final PlayerController player;
  final AuthController auth;
  final Song song;
  final VoidCallback onClose;
  final VoidCallback onQueue;
  final ValueChanged<Song> onArtistTap;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxHeight < 350;
        return Padding(
          padding: EdgeInsets.fromLTRB(
            compact ? 14 : 24,
            compact ? 4 : 10,
            compact ? 16 : 30,
            compact ? 24 : 36,
          ),
          child: Column(
            children: [
              _LandscapeHeader(
                player: player,
                auth: auth,
                song: song,
                onClose: onClose,
                compact: compact,
                onArtistTap: onArtistTap,
              ),
              SizedBox(height: compact ? 2 : 10),
              Expanded(
                child: Row(
                  children: [
                    Expanded(
                      flex: 9,
                      child: _LandscapeArtworkShowcase(
                        player: player,
                        song: song,
                        compact: compact,
                      ),
                    ),
                    SizedBox(width: compact ? 18 : 34),
                    Expanded(
                      flex: 12,
                      child: _LandscapeRightPanel(
                        player: player,
                        auth: auth,
                        song: song,
                        onQueue: onQueue,
                        compact: compact,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _LandscapeHeader extends StatelessWidget {
  const _LandscapeHeader({
    required this.player,
    required this.auth,
    required this.song,
    required this.onClose,
    required this.compact,
    required this.onArtistTap,
  });

  final PlayerController player;
  final AuthController auth;
  final Song song;
  final VoidCallback onClose;
  final bool compact;
  final ValueChanged<Song> onArtistTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: compact ? 40 : 48,
      child: Row(
        children: [
          _LandscapeHeaderButton(
            tooltip: '返回',
            size: compact ? 38 : 44,
            iconSize: compact ? 30 : 34,
            onPressed: onClose,
            icon: Icons.keyboard_arrow_left_rounded,
          ),
          SizedBox(width: compact ? 10 : 18),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  song.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: Colors.white.withValues(alpha: .92),
                    fontSize: compact ? 14 : 16,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                if (!compact)
                  Text(
                    song.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Colors.white.withValues(alpha: .7),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
              ],
            ),
          ),
          _PlayerAudioQualityPill(
            player: player,
            compact: compact,
          ),
          SizedBox(width: compact ? 6 : 8),
          Builder(
            builder: (moreButtonContext) => _LandscapeHeaderButton(
              tooltip: '更多',
              size: compact ? 38 : 44,
              iconSize: compact ? 22 : 24,
              onPressed: () => _showMoreSheet(moreButtonContext),
              icon: Icons.more_horiz_rounded,
            ),
          ),
        ],
      ),
    );
  }

  void _showMoreSheet(BuildContext context) {
    showSongActionSheet(
      context: context,
      song: song,
      // PC：锚定到"更多"按钮下方（context 已由调用点传入按钮级 context）。
      anchor: anchorBelow(context),
      actions: [
        SongSheetAction(
          icon: Icons.speed_rounded,
          title: '倍速播放',
          subtitle: player.playbackSpeedLabel,
          onTap: () => showPlaybackSpeedSheet(context: context, player: player),
        ),
        SongSheetAction(
          icon: Icons.high_quality_rounded,
          title: '音质：${player.audioQuality.label}',
          subtitle: '切换当前播放音质',
          onTap: () => _showAudioQualityPicker(context, player),
        ),
        SongSheetAction(
          icon: Icons.auto_awesome_rounded,
          title: '试听高潮',
          subtitle: '播放歌曲高潮片段',
          onTap: () async {
            final ok = await player.playClimaxPreview();
            if (!ok) Toast.error('暂无高潮片段');
          },
        ),
        if (player.isAudioEffectsSupported)
          SongSheetAction(
            icon: Icons.graphic_eq_rounded,
            title: '音效',
            subtitle: player.audioEffectsLabel,
            onTap: () => showAudioEffectsSheet(
              context: context,
              player: player,
            ),
          ),
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
        SongSheetAction(
          icon: Icons.bedtime_rounded,
          title: '定时播放',
          subtitle: player.isSleepTimerActive
              ? '剩余 ${_formatSleepRemaining(player.sleepTimerRemaining)}'
              : player.isSleepFinishCurrentSong
              ? '播完歌曲后停止'
              : null,
          onTap: () => showSleepTimerSheet(context: context, player: player),
        ),
        if (player.isDesktopLyricsSupported) ...[
          SongSheetAction(
            icon: player.desktopLyricsEnabled
                ? Icons.lyrics_rounded
                : Icons.lyrics_outlined,
            title: '桌面歌词',
            subtitle: player.desktopLyricsEnabled ? '已开启' : '已关闭',
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
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => DesktopLyricsSettingsPage(player: player),
                ),
              ),
            ),
        ],
      ],
    );
  }
}

class _LandscapeHeaderButton extends StatelessWidget {
  const _LandscapeHeaderButton({
    required this.tooltip,
    required this.size,
    required this.iconSize,
    required this.onPressed,
    required this.icon,
  });

  final String tooltip;
  final double size;
  final double iconSize;
  final VoidCallback? onPressed;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.white.withValues(alpha: .12),
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: SizedBox.square(
          dimension: size,
          child: IconButton(
            color: Colors.white,
            iconSize: iconSize,
            padding: EdgeInsets.zero,
            constraints: BoxConstraints.tightFor(width: size, height: size),
            onPressed: onPressed,
            icon: Icon(icon),
          ),
        ),
      ),
    );
  }
}

class _PlayerAudioQualityPill extends StatelessWidget {
  const _PlayerAudioQualityPill({
    required this.player,
    this.compact = false,
  });

  final PlayerController player;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: player,
      builder: (context, _) {
        final quality = player.audioQuality;
        final isLossless = quality == AudioQuality.lossless;
        final label = switch (quality) {
          AudioQuality.standard => '标准',
          AudioQuality.high => '高品',
          AudioQuality.lossless => '无损',
        };
        final tooltip = '音质：${quality.label} (${quality.badge}) - 点击切换';

        return Tooltip(
          message: tooltip,
          child: Material(
            color: Colors.white.withValues(alpha: .14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(
                color: isLossless
                    ? Theme.of(context).colorScheme.primary.withValues(alpha: .6)
                    : Colors.white.withValues(alpha: .18),
                width: 0.8,
              ),
            ),
            clipBehavior: Clip.antiAlias,
            child: Builder(
              builder: (pillContext) => InkWell(
                mouseCursor: SystemMouseCursors.click,
                onTap: () {
                  final anchor = isDesktopFormFactor
                      ? anchorBelow(pillContext)
                      : null;
                  _showAudioQualityPicker(pillContext, player, anchor: anchor);
                },
                child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: compact ? 8 : 10,
                  vertical: compact ? 4 : 6,
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
                          color: Theme.of(context)
                              .colorScheme
                              .primary
                              .withValues(alpha: .28),
                          borderRadius: BorderRadius.circular(3),
                        ),
                        child: Text(
                          'SQ',
                          style: TextStyle(
                            fontSize: compact ? 8 : 9,
                            fontWeight: FontWeight.w900,
                            color: Theme.of(context).colorScheme.primary,
                            height: 1.1,
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                    ],
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: compact ? 11 : 12,
                        fontWeight: FontWeight.w700,
                        color: Colors.white.withValues(alpha: .92),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      },
    );
  }
}

class _LandscapeArtworkShowcase extends StatefulWidget {
  const _LandscapeArtworkShowcase({
    required this.player,
    required this.song,
    required this.compact,
  });

  final PlayerController player;
  final Song song;
  final bool compact;

  @override
  State<_LandscapeArtworkShowcase> createState() =>
      _LandscapeArtworkShowcaseState();
}

class _LandscapeArtworkShowcaseState extends State<_LandscapeArtworkShowcase>
    with SingleTickerProviderStateMixin {
  late final AnimationController _rotationController;

  @override
  void initState() {
    super.initState();
    _rotationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 32),
    );
    _syncRotation();
  }

  @override
  void didUpdateWidget(covariant _LandscapeArtworkShowcase oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.song.hash != widget.song.hash) {
      _rotationController.value = 0;
    }
    _syncRotation();
  }

  @override
  void dispose() {
    _rotationController.dispose();
    super.dispose();
  }

  void _syncRotation() {
    if (widget.player.isPlaying) {
      if (!_rotationController.isAnimating) {
        _rotationController.repeat();
      }
    } else if (_rotationController.isAnimating) {
      _rotationController.stop(canceled: false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragEnd: (details) {
        final velocity = details.primaryVelocity ?? 0.0;
        if (velocity < -200) {
          widget.player.next();
        } else if (velocity > 200) {
          widget.player.previous();
        }
      },
      child: LayoutBuilder(
        builder: (context, constraints) {
          final available = math.min(
            constraints.maxWidth,
            constraints.maxHeight,
          );
          final discSize = (available * (widget.compact ? .84 : .9))
              .clamp(150.0, 330.0)
              .toDouble();
          final coverSize = discSize * (widget.compact ? .58 : .70);

          return Center(
            // 旋转唱片是纯装饰动画，排除语义树防止 Windows AXTree 竞态崩溃
            child: ExcludeSemantics(
              child: SizedBox.square(
                dimension: discSize,
                child: AnimatedBuilder(
                  animation: _rotationController,
                  builder: (context, child) {
                    return Transform.rotate(
                      angle: _rotationController.value * math.pi * 2,
                      child: child,
                    );
                  },
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      DecoratedBox(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: RadialGradient(
                            colors: [
                              Colors.white.withValues(alpha: .88),
                              Colors.white.withValues(alpha: .58),
                              Colors.white.withValues(alpha: .22),
                            ],
                            stops: const [0, .62, 1],
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: .26),
                              blurRadius: 30,
                              offset: const Offset(0, 18),
                            ),
                          ],
                        ),
                        child: const SizedBox.expand(),
                      ),
                      for (final ratio in const [.36, .52, .68, .82])
                        SizedBox.square(
                          dimension: discSize * ratio,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: Colors.white.withValues(alpha: .16),
                              ),
                            ),
                          ),
                        ),
                      ClipOval(
                        child: Artwork(
                          url: widget.song.coverUrl,
                          size: coverSize,
                          borderRadius: coverSize,
                        ),
                      ),
                      SizedBox.square(
                        dimension: discSize * .08,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.white.withValues(alpha: .82),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _LandscapeRightPanel extends StatelessWidget {
  const _LandscapeRightPanel({
    required this.player,
    required this.auth,
    required this.song,
    required this.onQueue,
    required this.compact,
  });

  final PlayerController player;
  final AuthController auth;
  final Song? song;
  final VoidCallback onQueue;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final currentSong = song;
    return LayoutBuilder(
      builder: (context, constraints) {
        final veryTight = constraints.maxHeight < 250;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (currentSong != null)
              Padding(
                padding: EdgeInsets.only(
                  bottom: veryTight ? 6.0 : 12.0,
                  top: veryTight ? 2.0 : 6.0,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      currentSong.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        color: Colors.white.withValues(alpha: .92),
                        fontSize: compact ? 18 : 22,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      currentSong.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Colors.white.withValues(alpha: .6),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: _LandscapeLyricPanel(
                player: player,
                songHash: currentSong?.hash ?? '',
                lyrics: player.lyrics,
                compact: compact || veryTight,
              ),
            ),
            SizedBox(height: veryTight ? 2 : 6),
            _Progress(player: player, bright: true, compact: true),
            SizedBox(height: veryTight ? 0 : 4),
            _Controls(
              player: player,
              bright: true,
              onQueue: onQueue,
              compactOverride: true,
              denseOverride: veryTight,
              likeAuth: auth,
              likeSong: song,
            ),
          ],
        );
      },
    );
  }
}

class _LandscapeLyricPanel extends StatefulWidget {
  const _LandscapeLyricPanel({
    required this.player,
    required this.songHash,
    required this.lyrics,
    required this.compact,
  });

  final PlayerController player;
  final String songHash;
  final List<LyricLine> lyrics;
  final bool compact;

  @override
  State<_LandscapeLyricPanel> createState() => _LandscapeLyricPanelState();
}

class _LandscapeLyricPanelState extends State<_LandscapeLyricPanel> {
  late final LyricController _lyricController;
  late final Ticker _ticker;
  bool _isUserSelecting = false;

  @override
  void initState() {
    super.initState();
    _lyricController = LyricController();
    _lyricController.setOnTapLineCallback((position) {
      widget.player.seek(position);
    });
    _lyricController.isSelectingNotifier.addListener(_onSelectingChanged);
    _syncLyrics();
    _ticker = Ticker(_onTick);
    _syncTicker();
  }

  @override
  void didUpdateWidget(covariant _LandscapeLyricPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.songHash != widget.songHash ||
        oldWidget.lyrics != widget.lyrics) {
      _syncLyrics();
    }
    _syncTicker();
  }

  @override
  void dispose() {
    _lyricController.isSelectingNotifier.removeListener(_onSelectingChanged);
    _ticker.dispose();
    _lyricController.dispose();
    super.dispose();
  }

  void _onSelectingChanged() {
    _isUserSelecting = _lyricController.isSelectingNotifier.value;
    _syncTicker();
  }

  void _syncLyrics() {
    final lyrics = widget.lyrics;
    if (lyrics.isNotEmpty) {
      final model = convertToFlutterLyricModel(lyrics);
      _lyricController.loadLyricModel(model);
    }
  }

  void _syncTicker() {
    final shouldTick =
        widget.player.isPlaying &&
        widget.lyrics.isNotEmpty &&
        !widget.player.isScrubbing &&
        !_isUserSelecting;
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
    _lyricController.setProgress(widget.player.smoothPosition);
  }

  @override
  Widget build(BuildContext context) {
    final player = widget.player;
    final lyrics = widget.lyrics;
    if (lyrics.isEmpty) {
      return Align(
        alignment: Alignment.centerLeft,
        child: Text(
          player.isPreparing ? '正在准备音乐...' : '暂无歌词',
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
            color: Colors.white.withValues(alpha: .82),
            fontWeight: FontWeight.w900,
          ),
        ),
      );
    }

    if (isDesktopFormFactor) {
      return ExcludeSemantics(
        child: _DesktopLyricList(
          player: player,
          songHash: widget.songHash,
          lyrics: lyrics,
          activeIndex: player.activeLyricIndex,
          displayMode: _LyricDisplayMode.lyricsOnly,
          lyricScale: widget.compact ? 0.85 : 1.0,
        ),
      );
    }

    final fontSize = widget.compact ? 26.0 : 34.0;
    final inactiveFontSize = widget.compact ? 18.0 : 24.0;

    return ExcludeSemantics(
      // 歌词视图高频更新会触发 Windows AXTree 竞态崩溃，排除语义树
      child: LyricView(
        controller: _lyricController,
        style: LyricStyles.default1.copyWith(
          textStyle: Theme.of(context).textTheme.titleLarge!.copyWith(
            color: Colors.white.withValues(alpha: .34),
            fontSize: inactiveFontSize,
            height: 1.18,
            fontWeight: FontWeight.w800,
          ),
          activeStyle: Theme.of(context).textTheme.headlineMedium!.copyWith(
            color: Colors.white.withValues(alpha: .34),
            fontSize: fontSize,
            height: 1.18,
            fontWeight: FontWeight.w900,
          ),
          lineGap: widget.compact ? 10 : 16,
          contentPadding: EdgeInsets.symmetric(
            horizontal: 24,
            vertical: widget.compact ? 20 : 40,
          ),
          fadeRange: FadeRange(top: 40, bottom: 40),
          textAlign: TextAlign.left,
          contentAlignment: CrossAxisAlignment.start,
          activeHighlightColor: Colors.white,
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
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
              _GlassIconButton(
                tooltip: liked ? '取消喜欢' : '喜欢',
                onPressed: song.source == SongSource.kugou
                    ? () => auth.toggleLike(song)
                    : null,
                icon: liked
                    ? Icons.favorite_rounded
                    : Icons.favorite_border_rounded,
              ),
              const SizedBox(width: 8),
              _PlayerAudioQualityPill(player: player),
              const SizedBox(width: 8),
              Builder(
                builder: (moreButtonContext) => _GlassIconButton(
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
          onTap: () => _showAudioQualityPicker(context, player),
        ),
        if (player.isAudioEffectsSupported)
          SongSheetAction(
            icon: Icons.graphic_eq_rounded,
            title: '音效',
            isGrid: true,
            onTap: () => showAudioEffectsSheet(
              context: context,
              player: player,
            ),
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

String _formatSleepRemaining(Duration? remaining) {
  if (remaining == null || remaining <= Duration.zero) return '';
  final minutes = remaining.inMinutes;
  final seconds = remaining.inSeconds.remainder(60);
  return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
}

class _PosterPlayerPage extends StatefulWidget {
  const _PosterPlayerPage({
    super.key,
    required this.player,
    required this.song,
    required this.onQueue,
  });

  final PlayerController player;
  final Song song;
  final VoidCallback onQueue;

  @override
  State<_PosterPlayerPage> createState() => _PosterPlayerPageState();
}

class _PosterPlayerPageState extends State<_PosterPlayerPage>
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
              _PosterLyricPreview(player: widget.player),
              if (!compact) const SizedBox(height: 4),
              _CommentEntry(player: widget.player, song: widget.song),
              const Spacer(),
              _Progress(player: widget.player, bright: true),
              const SizedBox(height: 10),
              _Controls(
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

int _activeLyricIndexFor(List<LyricLine> lyrics, Duration position) {
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

class _PosterLyricPreview extends StatefulWidget {
  const _PosterLyricPreview({required this.player});

  final PlayerController player;

  @override
  State<_PosterLyricPreview> createState() => _PosterLyricPreviewState();
}

class _PosterLyricPreviewState extends State<_PosterLyricPreview> {
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
  void didUpdateWidget(covariant _PosterLyricPreview oldWidget) {
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

    final index = _activeLyricIndexFor(lyrics, _position);
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
                child: _MarqueeSingleLine(
                  textKey: current.time.inMilliseconds,
                  child: _LyricText(
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
                child: _MarqueeSingleLine(
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

class _MarqueeSingleLine extends StatefulWidget {
  const _MarqueeSingleLine({required this.child, required this.textKey});

  final Widget child;
  final Object textKey;

  @override
  State<_MarqueeSingleLine> createState() => _MarqueeSingleLineState();
}

class _MarqueeSingleLineState extends State<_MarqueeSingleLine>
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
  void didUpdateWidget(covariant _MarqueeSingleLine oldWidget) {
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

class _LyricPlayerPage extends StatefulWidget {
  const _LyricPlayerPage({
    super.key,
    required this.player,
    required this.song,
    required this.focusRequest,
    required this.isPageActive,
    required this.isPageVisible,
    required this.isPageTransitioning,
  });

  final PlayerController player;
  final Song song;
  final int focusRequest;
  final bool isPageActive;
  final bool isPageVisible;
  final bool isPageTransitioning;

  @override
  State<_LyricPlayerPage> createState() => _LyricPlayerPageState();
}

class _LyricPlayerPageState extends State<_LyricPlayerPage>
    with AutomaticKeepAliveClientMixin {
  late _LyricDisplayMode _displayMode;

  /// 歌词字体缩放倍率（持久化）。
  static const _lyricScaleKey = 'settings.lyric_scale';
  double _lyricScale = 1.0;

  @override
  void initState() {
    super.initState();
    _displayMode = _initialLyricDisplayMode(widget.player.lyrics);
    _loadLyricScale();
    // 兜底：非点歌路径（恢复播放/静默失败）进页时歌词可能为空，补拉一次。
    unawaited(widget.player.ensureLyricsLoaded());
  }

  Future<void> _loadLyricScale() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() => _lyricScale = prefs.getDouble(_lyricScaleKey) ?? 1.0);
    }
  }

  Future<void> _setLyricScale(double scale) async {
    final clamped = scale.clamp(0.7, 1.6);
    setState(() => _lyricScale = clamped);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_lyricScaleKey, clamped);
  }

  @override
  bool get wantKeepAlive => true;

  @override
  void didUpdateWidget(covariant _LyricPlayerPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.song.hash != widget.song.hash ||
        oldWidget.player.lyrics != widget.player.lyrics) {
      _displayMode = _normalizeLyricDisplayMode(
        widget.player.lyrics,
        _displayMode,
      );
    }
    // 同一首歌但歌词为空（之前请求失败）：切回来时再补拉一次。
    if (oldWidget.song.hash == widget.song.hash &&
        widget.player.lyrics.isEmpty) {
      unawaited(widget.player.ensureLyricsLoaded());
    }
  }

  _LyricDisplayMode _initialLyricDisplayMode(List<LyricLine> lyrics) {
    final availableModes = _availableLyricDisplayModes(lyrics);
    return availableModes.isNotEmpty
        ? availableModes.first
        : _LyricDisplayMode.lyricsOnly;
  }

  _LyricDisplayMode _normalizeLyricDisplayMode(
    List<LyricLine> lyrics,
    _LyricDisplayMode currentMode,
  ) {
    final availableModes = _availableLyricDisplayModes(lyrics);
    if (availableModes.contains(currentMode)) {
      return currentMode;
    }
    return availableModes.isNotEmpty
        ? availableModes.first
        : _LyricDisplayMode.lyricsOnly;
  }

  void _toggleLyricDisplayMode() {
    final availableModes = _availableLyricDisplayModes(widget.player.lyrics);
    if (availableModes.length <= 1) {
      return;
    }

    final currentIndex = availableModes.indexOf(_displayMode);
    final nextIndex = currentIndex >= 0
        ? (currentIndex + 1) % availableModes.length
        : 0;
    setState(() => _displayMode = availableModes[nextIndex]);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final availableModes = _availableLyricDisplayModes(widget.player.lyrics);
    final canToggleLyricDisplayMode = availableModes.length > 1;
    final displayMode = _normalizeLyricDisplayMode(
      widget.player.lyrics,
      _displayMode,
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 18),
      child: Stack(
        children: [
          _LyricViewport(
            player: widget.player,
            songHash: widget.song.hash,
            lyrics: widget.player.lyrics,
            activeIndex: widget.player.activeLyricIndex,
            seekRevision: widget.player.seekRevision,
            isPreparing: widget.player.isPreparing,
            displayMode: displayMode,
            focusRequest: widget.focusRequest,
            isPageActive: widget.isPageActive,
            isPageVisible: widget.isPageVisible,
            isPageTransitioning: widget.isPageTransitioning,
            lyricScale: _lyricScale,
          ),
          // 字体大小调节按钮（左侧底部）
          Positioned(
            left: 0,
            bottom: 16,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _GlassIconButton(
                  tooltip: '缩小歌词',
                  onPressed: () => _setLyricScale(_lyricScale - 0.1),
                  icon: Icons.text_decrease_rounded,
                ),
                const SizedBox(width: 8),
                _GlassIconButton(
                  tooltip: '放大歌词',
                  onPressed: () => _setLyricScale(_lyricScale + 0.1),
                  icon: Icons.text_increase_rounded,
                ),
              ],
            ),
          ),
          if (canToggleLyricDisplayMode)
            Positioned(
              right: 0,
              bottom: 16,
              child: _GlassIconButton(
                tooltip: '切换歌词模式（当前：${_lyricDisplayModeLabel(displayMode)}）',
                onPressed: _toggleLyricDisplayMode,
                icon: switch (displayMode) {
                  _LyricDisplayMode.lyricsWithTranslation =>
                    Icons.translate_rounded,
                  _LyricDisplayMode.lyricsWithRomanization =>
                    Icons.record_voice_over_rounded,
                  _LyricDisplayMode.lyricsOnly => Icons.lyrics_rounded,
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _LyricViewport extends StatefulWidget {
  const _LyricViewport({
    required this.player,
    required this.songHash,
    required this.lyrics,
    required this.activeIndex,
    required this.seekRevision,
    required this.isPreparing,
    required this.displayMode,
    required this.focusRequest,
    required this.isPageActive,
    required this.isPageVisible,
    required this.isPageTransitioning,
    required this.lyricScale,
  });

  final PlayerController player;
  final String songHash;
  final List<LyricLine> lyrics;
  final int activeIndex;
  final int seekRevision;
  final bool isPreparing;
  final _LyricDisplayMode displayMode;
  final int focusRequest;
  final bool isPageActive;
  final bool isPageVisible;
  final bool isPageTransitioning;
  final double lyricScale;

  @override
  State<_LyricViewport> createState() => _LyricViewportState();
}

class _LyricViewportState extends State<_LyricViewport>
    with SingleTickerProviderStateMixin {
  late final LyricController _lyricController;
  late final Ticker _ticker;
  // flutter_lyric 内部通过 isSelectingNotifier 标记用户是否在拖动歌词。
  // LyricView 是 CustomPaint 自绘，不产生 ScrollNotification，外层
  // NotificationListener 无效；改为监听 isSelectingNotifier 控制 ticker，
  // 用户拖动时停止 setProgress，避免与 flutter_lyric 内部 fling/恢复竞态。
  bool _isUserSelecting = false;

  @override
  void initState() {
    super.initState();
    _lyricController = LyricController();
    _lyricController.setOnTapLineCallback((position) {
      widget.player.seek(position);
    });
    _lyricController.isSelectingNotifier.addListener(_onSelectingChanged);
    _syncLyrics();
    _ticker = Ticker(_onTick);
    _syncTicker();
  }

  void _syncLyrics() {
    final lyrics = widget.lyrics;
    if (lyrics.isNotEmpty) {
      final showTranslation =
          widget.displayMode == _LyricDisplayMode.lyricsWithTranslation;
      final showRomanization =
          widget.displayMode == _LyricDisplayMode.lyricsWithRomanization;
      final model = convertToFlutterLyricModel(
        lyrics,
        showTranslation: showTranslation,
        showRomanization: showRomanization,
      );
      _lyricController.loadLyricModel(model);
    }
  }

  @override
  void didUpdateWidget(covariant _LyricViewport oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.songHash != widget.songHash ||
        oldWidget.lyrics != widget.lyrics ||
        oldWidget.displayMode != widget.displayMode) {
      _syncLyrics();
    }
    _syncTicker();
  }

  @override
  void dispose() {
    _lyricController.isSelectingNotifier.removeListener(_onSelectingChanged);
    _ticker.dispose();
    _lyricController.dispose();
    super.dispose();
  }

  void _onSelectingChanged() {
    _isUserSelecting = _lyricController.isSelectingNotifier.value;
    _syncTicker();
  }

  void _syncTicker() {
    final shouldTick =
        widget.isPageVisible &&
        widget.player.isPlaying &&
        widget.lyrics.isNotEmpty &&
        !widget.player.isScrubbing &&
        !_isUserSelecting;
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
    _lyricController.setProgress(widget.player.smoothPosition);
  }

  @override
  Widget build(BuildContext context) {
    final lyrics = widget.lyrics;
    if (lyrics.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              widget.isPreparing ? '正在准备音乐...' : '暂无歌词',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w800,
              ),
            ),
            // 非 preparing 且无歌词：大概率是之前请求失败，给手动重试入口。
            if (!widget.isPreparing)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: _GlassIconButton(
                  tooltip: '重新加载歌词',
                  onPressed: () =>
                      unawaited(widget.player.ensureLyricsLoaded()),
                  icon: Icons.refresh_rounded,
                ),
              ),
          ],
        ),
      );
    }

    // 桌面端：flutter_lyric 的 LyricView 只处理触摸拖动，不响应鼠标滚轮；
    // 且控制器无对外滚动接口。用原生 ListView 实现 PC 式歌词列表：
    // 滚轮/触摸均可滚动，点击切歌，空闲自动跟随。
    if (isDesktopFormFactor) {
      return ExcludeSemantics(
        child: _DesktopLyricList(
          player: widget.player,
          songHash: widget.songHash,
          lyrics: lyrics,
          activeIndex: widget.activeIndex,
          displayMode: widget.displayMode,
          lyricScale: widget.lyricScale,
        ),
      );
    }

    final normalSize = 27.0 * widget.lyricScale;
    final activeSize = 34.0 * widget.lyricScale;
    final translationSize = 16.0 * widget.lyricScale;

    final lyricStyle = LyricStyles.default1.copyWith(
      textStyle: Theme.of(context).textTheme.headlineMedium!.copyWith(
        color: Colors.white.withValues(alpha: .34),
        fontSize: normalSize,
        height: 1.24,
        fontWeight: FontWeight.w800,
      ),
      activeStyle: Theme.of(context).textTheme.headlineMedium!.copyWith(
        color: Colors.white.withValues(alpha: .34),
        fontSize: activeSize,
        height: 1.24,
        fontWeight: FontWeight.w900,
      ),
      translationStyle: Theme.of(context).textTheme.titleMedium!.copyWith(
        color: Colors.white.withValues(alpha: .54),
        fontSize: translationSize,
        height: 1.28,
        fontWeight: FontWeight.w700,
      ),
      lineGap: 28,
      translationLineGap: 8,
      contentPadding: const EdgeInsets.fromLTRB(20, 180, 20, 220),
      fadeRange: FadeRange(top: 80, bottom: 80),
      textAlign: TextAlign.start,
      contentAlignment: CrossAxisAlignment.start,
      activeAnchorPosition: 0.34,
      activeHighlightColor: Colors.white,
    );

    return ExcludeSemantics(
      // 歌词视图高频更新会触发 Windows AXTree 竞态崩溃，排除语义树
      child: LyricView(controller: _lyricController, style: lyricStyle),
    );
  }
}

/// 桌面端歌词列表（PC 软件逻辑，对齐 QQ 音乐/网易云 PC）。
///
/// - 滚轮/触摸均可自由滚动歌词（flutter_lyric 自绘视图不消费滚轮，故用原生
///   ListView 实现）；点击行跳转播放；
/// - 用户滚动时暂停自动跟随（高亮仍随播放更新），停止滚动 3s 后平滑恢复
///   跟随当前行（主流 PC 播放器一致：QQ/网易云均为“手动查看 + 空闲恢复”，
///   本实现 3s 与业界常用值一致）；
/// - 手动滚动期间右下角出现“回到当前”快捷入口，点按立即恢复跟随。
class _DesktopLyricList extends StatefulWidget {
  const _DesktopLyricList({
    required this.player,
    required this.songHash,
    required this.lyrics,
    required this.activeIndex,
    required this.displayMode,
    required this.lyricScale,
  });

  final PlayerController player;
  final String songHash;
  final List<LyricLine> lyrics;
  final int activeIndex;
  final _LyricDisplayMode displayMode;
  final double lyricScale;

  @override
  State<_DesktopLyricList> createState() => _DesktopLyricListState();
}

class _DesktopLyricListState extends State<_DesktopLyricList> {
  // 主流 PC 播放器（QQ 音乐/网易云）用户干预后约 3.5s 恢复自动跟随。
  static const _resumeDelay = Duration(milliseconds: 3500);

  final _scrollController = ScrollController();
  final _rowKeys = <int, GlobalKey>{};
  Timer? _resumeTimer;
  var _userHolding = false;
  var _lastActive = -1;
  int? _focusedIndex;

  @override
  void initState() {
    super.initState();
    _lastActive = widget.activeIndex;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scrollToActive(animate: false);
    });
  }

  @override
  void didUpdateWidget(covariant _DesktopLyricList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.songHash != widget.songHash) {
      _rowKeys.clear();
      _resumeTimer?.cancel();
      _userHolding = false;
      _focusedIndex = null;
      _lastActive = widget.activeIndex;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _scrollToActive(animate: false);
      });
      return;
    }
    // 歌词异步加载完成（空 -> 有）时补一次定位；首帧行 key 尚未创建，
    // 放到 postFrame 等行构建完再滚。
    if (oldWidget.lyrics.length != widget.lyrics.length) {
      _lastActive = widget.activeIndex;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_userHolding) _scrollToActive(animate: false);
      });
      return;
    }
    if (widget.activeIndex != _lastActive) {
      _lastActive = widget.activeIndex;
      if (!_userHolding) {
        _scrollToActive(animate: true);
      }
    }
  }

  @override
  void dispose() {
    _resumeTimer?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToActive({required bool animate}) {
    if (!mounted || widget.activeIndex < 0) return;
    final key = _rowKeys[widget.activeIndex];
    final rowContext = key?.currentContext;
    if (rowContext == null) return;
    Scrollable.ensureVisible(
      rowContext,
      alignment: 0.38,
      duration: animate ? const Duration(milliseconds: 280) : Duration.zero,
      curve: Curves.easeOutCubic,
    );
  }

  void _updateFocusedIndex(double viewportHeight) {
    if (widget.lyrics.isEmpty) return;
    final targetY = viewportHeight * 0.38;
    int bestIndex = widget.activeIndex.clamp(0, widget.lyrics.length - 1);
    double minDiff = double.infinity;

    final stackRender = context.findRenderObject() as RenderBox?;
    if (stackRender == null || !stackRender.hasSize) return;

    for (final entry in _rowKeys.entries) {
      final key = entry.value;
      final ctx = key.currentContext;
      if (ctx == null) continue;
      final box = ctx.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) continue;
      final localCenter = box.localToGlobal(
        Offset(0, box.size.height / 2),
        ancestor: stackRender,
      );
      final diff = (localCenter.dy - targetY).abs();
      if (diff < minDiff) {
        minDiff = diff;
        bestIndex = entry.key;
      }
    }

    if (_focusedIndex != bestIndex) {
      setState(() {
        _focusedIndex = bestIndex;
      });
    }
  }

  void _startUserHolding(double viewportHeight) {
    _resumeTimer?.cancel();
    if (!_userHolding) {
      setState(() => _userHolding = true);
    }
    _updateFocusedIndex(viewportHeight);
    _resumeTimer = Timer(_resumeDelay, () {
      if (!mounted) return;
      _resumeNow();
    });
  }

  bool _handleScrollNotification(
    ScrollNotification notification,
    double viewportHeight,
  ) {
    if (!_userHolding) return false;

    if (notification is ScrollUpdateNotification) {
      _resumeTimer?.cancel();
      _updateFocusedIndex(viewportHeight);
      _resumeTimer = Timer(_resumeDelay, () {
        if (!mounted) return;
        _resumeNow();
      });
    } else if (notification is ScrollEndNotification) {
      _resumeTimer?.cancel();
      _updateFocusedIndex(viewportHeight);
      _resumeTimer = Timer(_resumeDelay, () {
        if (!mounted) return;
        _resumeNow();
      });
    }
    return false;
  }

  void _resumeNow() {
    _resumeTimer?.cancel();
    if (!mounted) return;
    setState(() {
      _userHolding = false;
      _focusedIndex = null;
    });
    _scrollToActive(animate: true);
  }

  String? _secondaryText(LyricLine line) {
    return switch (widget.displayMode) {
      _LyricDisplayMode.lyricsWithTranslation =>
        line.translation?.isNotEmpty == true ? line.translation : null,
      _LyricDisplayMode.lyricsWithRomanization =>
        line.romanization?.isNotEmpty == true ? line.romanization : null,
      _LyricDisplayMode.lyricsOnly => null,
    };
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewportHeight = constraints.maxHeight;
        final targetY = viewportHeight * 0.38;
        final defaultIdx =
            widget.activeIndex.clamp(0, widget.lyrics.length - 1);
        final currentFocusIdx = _focusedIndex ?? defaultIdx;
        final focusedLine = (_userHolding &&
                currentFocusIdx >= 0 &&
                currentFocusIdx < widget.lyrics.length)
            ? widget.lyrics[currentFocusIdx]
            : null;

        return Stack(
          children: [
            Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: (_) => _startUserHolding(viewportHeight),
              onPointerSignal: (signal) {
                if (signal is PointerScrollEvent) {
                  _startUserHolding(viewportHeight);
                }
              },
              child: NotificationListener<ScrollNotification>(
                onNotification: (notification) =>
                    _handleScrollNotification(notification, viewportHeight),
                child: ListView.builder(
                controller: _scrollController,
                physics: const AlwaysScrollableScrollPhysics(),
                padding: EdgeInsets.fromLTRB(
                  20,
                  targetY > 0 ? targetY : 120,
                  20,
                  viewportHeight * 0.48,
                ),
                itemCount: widget.lyrics.length,
                itemBuilder: (context, index) {
                  final line = widget.lyrics[index];
                  final isPlaying = index == widget.activeIndex;
                  final isFocused = _userHolding && index == _focusedIndex;
                  final isHighlighted = _userHolding ? isFocused : isPlaying;
                  final key = _rowKeys.putIfAbsent(index, GlobalKey.new);
                  final secondary = _secondaryText(line);

                  final Color textColor;
                  if (isHighlighted) {
                    textColor = Colors.white;
                  } else if (_userHolding && isPlaying) {
                    textColor = Colors.white.withValues(alpha: .52);
                  } else {
                    textColor = Colors.white.withValues(alpha: .32);
                  }

                  return GestureDetector(
                    key: key,
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      widget.player.seek(line.time);
                      if (!widget.player.isPlaying) {
                        widget.player.togglePlay();
                      }
                      _resumeNow();
                    },
                    child: MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 9),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            AnimatedDefaultTextStyle(
                              duration: const Duration(milliseconds: 180),
                              style: Theme.of(context)
                                  .textTheme
                                  .headlineMedium!
                                  .copyWith(
                                    color: textColor,
                                    fontSize: (isHighlighted ? 30.0 : 24.0) *
                                        widget.lyricScale,
                                    height: 1.3,
                                    fontWeight: isHighlighted
                                        ? FontWeight.w900
                                        : FontWeight.w700,
                                  ),
                              child: Text(line.text),
                            ),
                            if (secondary != null) ...[
                              const SizedBox(height: 4),
                              Text(
                                secondary,
                                style: Theme.of(context)
                                    .textTheme
                                    .titleMedium
                                    ?.copyWith(
                                      color: Colors.white.withValues(
                                        alpha: isHighlighted
                                            ? .75
                                            : (_userHolding && isPlaying ? .45 : .28),
                                      ),
                                      fontSize: 15.0 * widget.lyricScale,
                                      height: 1.3,
                                      fontWeight: FontWeight.w600,
                                    ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
            // 居中准星参考线与定位跳转播放按钮 [ ▶ mm:ss ]
            if (_userHolding && focusedLine != null)
              Positioned(
                left: 0,
                right: 12,
                top: targetY - 14,
                height: 28,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      child: Container(
                        height: 1,
                        margin: const EdgeInsets.only(right: 10),
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              Colors.white.withValues(alpha: 0.0),
                              Colors.white.withValues(alpha: 0.10),
                              Colors.white.withValues(alpha: 0.32),
                              Colors.white.withValues(alpha: 0.16),
                            ],
                          ),
                        ),
                      ),
                    ),
                    _SeekPointerButton(
                      key: const ValueKey('lyric_seek_pointer_button'),
                      timeText: formatDuration(focusedLine.time),
                      onTap: () {
                        widget.player.seek(focusedLine.time);
                        if (!widget.player.isPlaying) {
                          widget.player.togglePlay();
                        }
                        _resumeNow();
                      },
                    ),
                  ],
                ),
              ),
            // 手动滚动期间的“回到当前”快捷入口（网易云/QQ 音乐 PC 同款逻辑，
            // 自动恢复前给用户手动立即跟随的出口）。
            if (_userHolding)
              Positioned(
                right: 12,
                bottom: 24,
                child: Material(
                  color: Colors.white.withValues(alpha: .14),
                  borderRadius: BorderRadius.circular(20),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: _resumeNow,
                    borderRadius: BorderRadius.circular(20),
                    child: const Padding(
                      padding:
                          EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.my_location_rounded,
                            size: 16,
                            color: Colors.white,
                          ),
                          SizedBox(width: 6),
                          Text(
                            '回到当前',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// PC 端歌词定位播放准星按钮 [ ▶ mm:ss ]
class _SeekPointerButton extends StatefulWidget {
  const _SeekPointerButton({
    super.key,
    required this.timeText,
    required this.onTap,
  });

  final String timeText;
  final VoidCallback onTap;

  @override
  State<_SeekPointerButton> createState() => _SeekPointerButtonState();
}

class _SeekPointerButtonState extends State<_SeekPointerButton> {
  bool _isHovering = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _isHovering = true),
      onExit: (_) => setState(() => _isHovering = false),
      child: Tooltip(
        message: '从 ${widget.timeText} 开始播放',
        child: GestureDetector(
          onTap: widget.onTap,
          behavior: HitTestBehavior.opaque,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: _isHovering
                  ? primary
                  : const Color(0xFF1E212B).withValues(alpha: 0.85),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: _isHovering
                    ? primary
                    : Colors.white.withValues(alpha: 0.35),
                width: 1,
              ),
              boxShadow: [
                BoxShadow(
                  color:
                      Colors.black.withValues(alpha: _isHovering ? 0.4 : 0.2),
                  blurRadius: 10,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.play_arrow_rounded,
                  size: 16,
                  color: Colors.white,
                ),
                const SizedBox(width: 4),
                Text(
                  widget.timeText,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
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

class _LyricText extends StatelessWidget {
  const _LyricText({
    required this.line,
    required this.active,
    required this.position,
    this.styleOverride,
    this.textAlign = TextAlign.start,
    this.singleLine = false,
  });

  final LyricLine line;
  final bool active;
  final Duration position;
  final TextStyle? styleOverride;
  final TextAlign textAlign;
  final bool singleLine;

  @override
  Widget build(BuildContext context) {
    final style =
        styleOverride ??
        Theme.of(context).textTheme.headlineMedium!.copyWith(
          color: Colors.white,
          fontSize: active ? 34 : 27,
          height: 1.24,
          fontWeight: active ? FontWeight.w900 : FontWeight.w800,
        );

    if (!active || line.words.isEmpty) {
      if (singleLine) {
        return Text(
          line.text,
          textAlign: textAlign,
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.visible,
          style: style,
        );
      }
      return Text(line.text, textAlign: textAlign, style: style);
    }

    if (singleLine) {
      final painter = _KaraokeLinePainter(
        line: line,
        position: position,
        style: style,
        baseColor: Colors.white.withValues(alpha: .34),
        activeColor: Colors.white,
        textDirection: Directionality.of(context),
        textAlign: textAlign,
        maxLines: 1,
        maxWidth: double.infinity,
      );
      return CustomPaint(
        size: Size(painter.width, painter.height),
        painter: painter,
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final painter = _KaraokeLinePainter(
          line: line,
          position: position,
          style: style,
          baseColor: Colors.white.withValues(alpha: .34),
          activeColor: Colors.white,
          textDirection: Directionality.of(context),
          textAlign: textAlign,
          maxLines: null,
          maxWidth: constraints.maxWidth,
        );
        return CustomPaint(
          size: Size(constraints.maxWidth, painter.height),
          painter: painter,
        );
      },
    );
  }
}

class _KaraokeLinePainter extends CustomPainter {
  _KaraokeLinePainter({
    required this.line,
    required this.position,
    required this.style,
    required this.baseColor,
    required this.activeColor,
    required this.textDirection,
    required this.textAlign,
    required this.maxLines,
    required this.maxWidth,
  }) {
    _textPainter = TextPainter(
      text: TextSpan(
        text: line.text,
        style: style.copyWith(color: baseColor),
      ),
      textDirection: textDirection,
      textAlign: textAlign,
      maxLines: maxLines,
    )..layout(maxWidth: maxLines == 1 ? double.infinity : maxWidth);
  }

  final LyricLine line;
  final Duration position;
  final TextStyle style;
  final Color baseColor;
  final Color activeColor;
  final TextDirection textDirection;
  final TextAlign textAlign;
  final int? maxLines;
  final double maxWidth;
  late final TextPainter _textPainter;

  double get width => _textPainter.width;
  double get height => _textPainter.height;

  @override
  void paint(Canvas canvas, Size size) {
    _textPainter.paint(canvas, Offset.zero);

    var start = 0;
    for (final word in line.words) {
      final end = start + word.text.length;
      final progress = _wordProgress(word);
      if (progress > 0) {
        _paintWordProgress(canvas, start, end, progress);
      }
      start = end;
    }
  }

  double _wordProgress(LyricWord word) {
    if (position < word.time) return 0;
    final durationMs = word.duration.inMilliseconds;
    if (durationMs <= 0) return 1;
    final elapsed = position.inMilliseconds - word.time.inMilliseconds;
    return (elapsed / durationMs).clamp(0, 1).toDouble();
  }

  void _paintWordProgress(Canvas canvas, int start, int end, double progress) {
    final selection = TextSelection(baseOffset: start, extentOffset: end);
    final boxes = _textPainter.getBoxesForSelection(selection);
    if (boxes.isEmpty) return;

    final highlightPainter = TextPainter(
      text: TextSpan(
        text: line.text,
        style: style.copyWith(color: activeColor),
      ),
      textDirection: textDirection,
      textAlign: textAlign,
      maxLines: maxLines,
    )..layout(maxWidth: maxLines == 1 ? double.infinity : maxWidth);

    for (final box in boxes) {
      final rect = box.toRect();
      final clipWidth = rect.width * progress.clamp(0, 1);
      if (clipWidth <= 0) continue;

      canvas.save();
      canvas.clipRect(
        Rect.fromLTWH(rect.left, rect.top, clipWidth, rect.height),
      );
      highlightPainter.paint(canvas, Offset.zero);
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _KaraokeLinePainter oldDelegate) {
    return oldDelegate.position != position ||
        oldDelegate.line != line ||
        oldDelegate.style != style ||
        oldDelegate.maxWidth != maxWidth;
  }
}

class _Progress extends StatelessWidget {
  const _Progress({
    required this.player,
    this.bright = false,
    this.compact = false,
  });

  final PlayerController player;
  final bool bright;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final textColor = bright
        ? Colors.white.withValues(alpha: .64)
        : Theme.of(context).colorScheme.onSurfaceVariant;

    return ValueListenableBuilder<Duration>(
      valueListenable: player.positionListenable,
      builder: (context, _, _) {
        final max = player.duration.inMilliseconds <= 0
            ? 1.0
            : player.duration.inMilliseconds.toDouble();
        final pos = player.smoothPosition;
        final value = pos.inMilliseconds.clamp(0, max.toInt()).toDouble();
        // 高潮起始位置映射为 0..1，在轨道内部画一个小标记。
        final climax = player.climax;
        final durationMs = player.duration.inMilliseconds;
        double? climaxStart;
        if (climax != null && climax.isValid && durationMs > 0) {
          final start = (climax.startTime.inMilliseconds / durationMs).clamp(
            0.0,
            1.0,
          );
          if (start > 0 && start < 1.0) {
            climaxStart = start;
          }
        }

        return Column(
          children: [
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: compact ? 3 : 5,
                thumbShape: RoundSliderThumbShape(
                  enabledThumbRadius: compact ? 4 : 5,
                ),
                overlayShape: RoundSliderOverlayShape(
                  overlayRadius: compact ? 10 : 14,
                ),
                activeTrackColor: bright
                    ? Colors.white.withValues(alpha: .86)
                    : Theme.of(context).colorScheme.primary,
                inactiveTrackColor: bright
                    ? Colors.white.withValues(alpha: .25)
                    : Theme.of(context).colorScheme.surfaceContainerHighest,
                thumbColor: Colors.white,
                trackShape: _ClimaxSliderTrackShape(
                  climaxStart: climaxStart,
                  markerColor: bright
                      ? Colors.white.withValues(alpha: .55)
                      : Theme.of(
                          context,
                        ).colorScheme.primary.withValues(alpha: .45),
                ),
              ),
              child: Slider(
                value: value,
                max: max,
                onChanged: (value) =>
                    player.previewSeek(Duration(milliseconds: value.round())),
                onChangeEnd: (value) =>
                    player.seek(Duration(milliseconds: value.round())),
              ),
            ),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: compact ? 2 : 4),
              child: Row(
                children: [
                  Text(
                    formatDuration(pos),
                    style: TextStyle(
                      color: textColor,
                      fontSize: compact ? 12 : null,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    formatDuration(player.duration),
                    style: TextStyle(
                      color: textColor,
                      fontSize: compact ? 12 : null,
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 播放页进度条的高潮标记轨道已抽到共享组件 [ClimaxSliderTrackShape]
/// （`lib/ui/widgets/climax_slider_track.dart`），与桌面底部播放栏共用，
/// 此处保留别名以收敛改动。
typedef _ClimaxSliderTrackShape = ClimaxSliderTrackShape;

class _Controls extends StatelessWidget {
  const _Controls({
    required this.player,
    required this.onQueue,
    this.bright = false,
    this.compactOverride = false,
    this.denseOverride = false,
    this.likeAuth,
    this.likeSong,
  });

  final PlayerController player;
  final VoidCallback onQueue;
  final bool bright;
  final bool compactOverride;
  final bool denseOverride;
  final AuthController? likeAuth;
  final Song? likeSong;

  @override
  Widget build(BuildContext context) {
    final color = bright
        ? Colors.white
        : Theme.of(context).colorScheme.onSurface;
    final size = MediaQuery.sizeOf(context);
    final isLandscape = size.width > size.height;

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = compactOverride || constraints.maxWidth < 360;
        final dense = denseOverride;
        // 超大按钮仅在车机模式开启时使用，普通横屏用标准尺寸。
        final isCar = isLandscape && ThemeController.instance.carModeEnabled;
        final edgeButtonSize = dense
            ? 34.0
            : (isCar ? 56.0 : (compact ? 40.0 : 44.0));
        final edgeIconSize = dense
            ? 21.0
            : (isCar ? 34.0 : (compact ? 24.0 : 27.0));
        final skipButtonSize = dense
            ? 42.0
            : (isCar ? 72.0 : (compact ? 50.0 : 56.0));
        final skipIconSize = dense
            ? 33.0
            : (isCar ? 54.0 : (compact ? 40.0 : 46.0));
        final playButtonSize = dense
            ? 58.0
            : (isCar ? 96.0 : (compact ? 72.0 : 82.0));
        final playIconSize = dense
            ? 46.0
            : (isCar ? 72.0 : (compact ? 56.0 : 64.0));
        final gap = dense ? 3.0 : (isCar ? 24.0 : (compact ? 5.0 : 9.0));
        final likeAuth = this.likeAuth;
        final likeSong = this.likeSong;
        final showLike =
            isCar && likeAuth != null && likeSong != null;

        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // 车机模式：爱心放在播放模式按钮左侧，方便近距离触控。
            if (showLike) ...[
              AnimatedBuilder(
                animation: likeAuth,
                builder: (context, _) {
                  final liked = likeAuth.isLiked(likeSong);
                  return SizedBox.square(
                    dimension: edgeButtonSize,
                    child: IconButton(
                      tooltip: liked ? '取消喜欢' : '喜欢',
                      color: color,
                      iconSize: edgeIconSize,
                      padding: EdgeInsets.zero,
                      onPressed: likeSong.source == SongSource.kugou
                          ? () => likeAuth.toggleLike(likeSong)
                          : null,
                      icon: Icon(
                        liked
                            ? Icons.favorite_rounded
                            : Icons.favorite_border_rounded,
                      ),
                    ),
                  );
                },
              ),
              SizedBox(width: gap),
            ],
            SizedBox.square(
              dimension: edgeButtonSize,
              child: IconButton(
                tooltip: player.playbackModeLabel,
                color: color,
                iconSize: edgeIconSize,
                padding: EdgeInsets.zero,
                onPressed: () {
                  player.cyclePlaybackMode();
                  Toast.show(
                    '已切换到${player.playbackModeLabel}',
                    duration: const Duration(milliseconds: 1100),
                  );
                },
                icon: Icon(_playbackModeIcon(player.playbackMode)),
              ),
            ),
            SizedBox(width: gap),
            SizedBox.square(
              dimension: skipButtonSize,
              child: IconButton(
                tooltip: '上一首',
                color: color,
                iconSize: skipIconSize,
                padding: EdgeInsets.zero,
                onPressed: player.previous,
                icon: const Icon(Icons.skip_previous_rounded),
              ),
            ),
            SizedBox(width: gap),
            SizedBox.square(
              dimension: playButtonSize,
              child: IconButton(
                tooltip: player.isPlaying ? '暂停' : '播放',
                color: color,
                padding: EdgeInsets.zero,
                onPressed: player.isPreparing ? null : player.togglePlay,
                iconSize: playIconSize,
                icon: player.isPreparing
                    ? SizedBox.square(
                        dimension: isCar ? 36 : (compact ? 24 : 28),
                        child: const CircularProgressIndicator(
                          strokeWidth: 3,
                          color: Colors.white,
                        ),
                      )
                    : Icon(
                        player.isPlaying
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                      ),
              ),
            ),
            SizedBox(width: gap),
            SizedBox.square(
              dimension: skipButtonSize,
              child: IconButton(
                tooltip: '下一首',
                color: color,
                iconSize: skipIconSize,
                padding: EdgeInsets.zero,
                onPressed: player.next,
                icon: const Icon(Icons.skip_next_rounded),
              ),
            ),
            SizedBox(width: gap),
            SizedBox.square(
              dimension: edgeButtonSize,
              child: IconButton(
                tooltip: '播放列表',
                color: color,
                iconSize: edgeIconSize,
                padding: EdgeInsets.zero,
                onPressed: onQueue,
                icon: const Icon(Icons.queue_music_rounded),
              ),
            ),
          ],
        );
      },
    );
  }

  IconData _playbackModeIcon(PlaybackMode mode) {
    return switch (mode) {
      PlaybackMode.playlistLoop => Icons.repeat_rounded,
      PlaybackMode.shuffle => Icons.shuffle_rounded,
      PlaybackMode.singleLoop => Icons.repeat_one_rounded,
    };
  }
}

class _GlassIconButton extends StatelessWidget {
  const _GlassIconButton({
    required this.tooltip,
    required this.onPressed,
    required this.icon,
  });

  final String tooltip;
  final VoidCallback? onPressed;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.white.withValues(alpha: .14),
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: IconButton(
          color: Colors.white,
          onPressed: onPressed,
          icon: Icon(icon),
        ),
      ),
    );
  }
}

class _CommentEntry extends StatelessWidget {
  const _CommentEntry({required this.player, required this.song});

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

class _PageDots extends StatelessWidget {
  const _PageDots({required this.page});

  final int page;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: List.generate(2, (index) {
          final active = index == page;
          return AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            width: active ? 18 : 7,
            height: 7,
            margin: const EdgeInsets.symmetric(horizontal: 4),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: active ? .86 : .32),
              borderRadius: BorderRadius.circular(99),
            ),
          );
        }),
      ),
    );
  }
}
