import 'dart:async';

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

class _PlayerBodyState extends State<_PlayerBody> {
  final _pageController = PageController(initialPage: 1);
  var _page = 1;
  var _pageScrolling = false;
  bool? _lastSystemUiLandscape;

  bool get _lyricPageVisible => _page == 0 || _pageScrolling;

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
                                      LyricPlayerPage(
                                        key: const PageStorageKey(
                                          'lyric-player-page',
                                        ),
                                        player: widget.player,
                                        song: widget.song,
                                        isPageVisible: _lyricPageVisible,
                                      ),
                                      PosterPlayerPage(
                                        key: const PageStorageKey(
                                          'poster-player-page',
                                        ),
                                        player: widget.player,
                                        song: widget.song,
                                        onQueue: widget.onQueue,
                                        auth: widget.auth,
                                        onArtistTap: _openArtist,
                                        onLyricTap: () {
                                          if (_pageController.hasClients) {
                                            _pageController.animateToPage(
                                              0,
                                              duration: const Duration(
                                                milliseconds: 250,
                                              ),
                                              curve: Curves.easeInOut,
                                            );
                                          }
                                        },
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
}

