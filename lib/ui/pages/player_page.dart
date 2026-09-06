import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../../controllers/auth_controller.dart';
import '../../controllers/player_controller.dart';
import '../../controllers/theme_controller.dart';
import '../../models/music_models.dart';
import '../form_factor.dart';
import '../player/landscape_player.dart';
import '../player/lyric_views.dart';
import '../player/player_backdrops.dart';
import '../player/player_top_bar.dart';
import '../player/poster_player.dart';
import '../widgets/artwork.dart';
import '../widgets/horizontal_wheel_scroll.dart';
import '../widgets/toast.dart';
import 'artist_detail_page.dart';

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

class _PlayerBodyState extends State<_PlayerBody>
    with SingleTickerProviderStateMixin {
  final _pageController = PageController(initialPage: 0);
  var _page = 0;
  var _pageScrolling = false;
  bool? _lastSystemUiLandscape;

  double _dragDownY = 0.0;
  double _dragDistance = 0.0;
  bool _isDismissing = false;
  late final AnimationController _dismissController;
  late Animation<double> _dismissAnimation;

  bool get _lyricPageVisible => _page == 1 || _pageScrolling;

  @override
  void initState() {
    super.initState();
    _dismissAnimation = const AlwaysStoppedAnimation(0.0);
    _dismissController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    )..addListener(() {
        setState(() {
          _dragDistance = _dismissAnimation.value;
        });
      })..addStatusListener((status) {
        if (status == AnimationStatus.completed && _isDismissing) {
          widget.onClose();
        }
      });
  }

  @override
  void dispose() {
    _dismissController.dispose();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _pageController.dispose();
    super.dispose();
  }

  void _onVerticalDragDown(DragDownDetails details) {
    if (_isDismissing) return;
    _dragDownY = details.globalPosition.dy;
  }

  void _onVerticalDragStart(DragStartDetails details) {
    if (_isDismissing) return;
    if (_dismissController.isAnimating) {
      _dismissController.stop();
    }
    final slop = details.globalPosition.dy - _dragDownY;
    if (slop > 0) {
      setState(() {
        _dragDistance = slop;
      });
    }
  }

  void _onVerticalDragUpdate(DragUpdateDetails details) {
    if (_isDismissing) return;
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
    if (_isDismissing) return;
    final velocity = details.primaryVelocity ?? 0.0;
    if (_dragDistance > 80.0 || velocity > 800.0) {
      _animateDismiss();
    } else {
      _animateReset();
    }
  }

  void _onVerticalDragCancel() {
    if (_isDismissing) return;
    if (_dragDistance > 0) {
      _animateReset();
    }
  }

  void _animateDismiss() {
    _isDismissing = true;
    final screenHeight = MediaQuery.sizeOf(context).height;
    _dismissAnimation = Tween<double>(
      begin: _dragDistance,
      end: screenHeight,
    ).animate(CurvedAnimation(
      parent: _dismissController,
      curve: Curves.easeInCubic,
    ));
    _dismissController.duration = const Duration(milliseconds: 200);
    _dismissController.forward(from: 0.0);
  }

  void _animateReset() {
    _isDismissing = false;
    _dismissAnimation = Tween<double>(
      begin: _dragDistance,
      end: 0.0,
    ).animate(CurvedAnimation(
      parent: _dismissController,
      curve: Curves.easeOutCubic,
    ));
    _dismissController.duration = const Duration(milliseconds: 250);
    _dismissController.forward(from: 0.0);
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
    final useSplitLayout =
        isDesktopFormFactor ||
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
          child: Transform.translate(
            key: const Key('player_body_dismiss_transform'),
            offset: Offset(0, _dragDistance),
            child: ClipRRect(
              key: const Key('player_body_dismiss_clip'),
              borderRadius: BorderRadius.vertical(
                top: Radius.circular(_dragDistance > 0 ? 12.0 : 0.0),
              ),
              child: Scaffold(
                backgroundColor: Colors.black,
                body: Stack(
                  children: [
                    ArtworkBackground(song: widget.song),
                    SafeArea(
                      // 横屏时同样需要处理顶部状态栏和底部系统导航栏（如车机空调控制栏）的遮挡。
                      // 竖屏已由外层 Scaffold 处理，这里对所有方向统一保留 SafeArea。
                      child: Column(
                        children: [
                          if (!useSplitLayout)
                            TopBar(
                              player: widget.player,
                              auth: widget.auth,
                              song: widget.song,
                              onClose: widget.onClose,
                              onArtistTap: _openArtist,
                              currentPage: _page,
                              onPageSelected: (index) =>
                                  _pageController.animateToPage(
                                index,
                                duration: const Duration(milliseconds: 250),
                                curve: Curves.easeInOut,
                              ),
                              onVerticalDragDown: _onVerticalDragDown,
                              onVerticalDragStart: _onVerticalDragStart,
                              onVerticalDragUpdate: _onVerticalDragUpdate,
                              onVerticalDragEnd: _onVerticalDragEnd,
                              onVerticalDragCancel: _onVerticalDragCancel,
                            ),
                          Expanded(
                            child: useSplitLayout
                                ? ExcludeSemantics(
                                    child: LandscapePlayerContent(
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
                                          PosterPlayerPage(
                                            key: const PageStorageKey(
                                              'poster-player-page',
                                            ),
                                            player: widget.player,
                                            song: widget.song,
                                            onQueue: widget.onQueue,
                                            auth: widget.auth,
                                            onArtistTap: _openArtist,
                                            onCoverTap: () => _showMoreSheet(context),
                                            onVerticalDragDown: _onVerticalDragDown,
                                            onVerticalDragStart:
                                                _onVerticalDragStart,
                                            onVerticalDragUpdate:
                                                _onVerticalDragUpdate,
                                            onVerticalDragEnd: _onVerticalDragEnd,
                                            onVerticalDragCancel:
                                                _onVerticalDragCancel,
                                            onLyricTap: () {
                                              if (_pageController.hasClients) {
                                                _pageController.animateToPage(
                                                  1,
                                                  duration: const Duration(
                                                    milliseconds: 250,
                                                  ),
                                                  curve: Curves.easeInOut,
                                                );
                                              }
                                            },
                                          ),
                                          LyricPlayerPage(
                                            key: const PageStorageKey(
                                              'lyric-player-page',
                                            ),
                                            player: widget.player,
                                            song: widget.song,
                                            isPageVisible: _lyricPageVisible,
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
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
    final nextPage = page ?? _page;
    final nextScrolling = scrolling ?? _pageScrolling;

    if (nextPage == _page && nextScrolling == _pageScrolling) {
      return;
    }

    setState(() {
      _page = nextPage;
      _pageScrolling = nextScrolling;
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

  void _showMoreSheet(BuildContext context) {
    showPlayerMoreSheet(
      context: context,
      player: widget.player,
      auth: widget.auth,
      song: widget.song,
    );
  }
}

