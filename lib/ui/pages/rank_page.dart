import 'dart:async';

import 'package:flutter/material.dart';

import '../../controllers/auth_controller.dart';
import '../../controllers/player_controller.dart';
import '../../controllers/theme_controller.dart';
import '../../models/music_models.dart';
import '../../services/music_api.dart';
import '../widgets/artwork.dart';
import '../widgets/mini_player.dart';
import '../widgets/song_action_sheets.dart';
import 'artist_detail_page.dart';

/// 排行榜页面 —— 展示酷狗各类榜单，点击榜单查看歌曲列表。
class RankPage extends StatefulWidget {
  const RankPage({
    super.key,
    required this.api,
    required this.auth,
    required this.player,
  });

  final MusicApi api;
  final AuthController auth;
  final PlayerController player;

  @override
  State<RankPage> createState() => _RankPageState();
}

class _RankPageState extends State<RankPage>
    with AutomaticKeepAliveClientMixin {
  Future<List<RankCategory>>? _future;
  Future<List<Song>>? _newSongsFuture;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _future = widget.api.rankList(withSong: 3);
    _newSongsFuture = widget.api.newSongs();
  }

  Future<void> _refresh() async {
    final rankFuture = widget.api.rankList(withSong: 3);
    final songsFuture = widget.api.newSongs();
    setState(() {
      _future = rankFuture;
      _newSongsFuture = songsFuture;
    });
    // FutureBuilder 各自处理错误，这里只需等待完成，忽略异常
    try {
      await Future.wait([rankFuture, songsFuture], eagerError: false);
    } catch (_) {}
  }

  void _openRankDetail(RankCategory rank) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => RankDetailPage(
          api: widget.api,
          auth: widget.auth,
          player: widget.player,
          rank: rank,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final size = MediaQuery.sizeOf(context);
    final isCarLandscape =
        size.width > size.height && ThemeController.instance.carModeEnabled;

    return FutureBuilder<List<RankCategory>>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting &&
            !snapshot.hasData) {
          return _RankSkeleton(isCarLandscape: isCarLandscape);
        }
        if (snapshot.hasError && !snapshot.hasData) {
          return _RankError(
            message: snapshot.error.toString(),
            onRetry: _refresh,
          );
        }
        final ranks = snapshot.data ?? [];
        if (ranks.isEmpty) {
          return const _RankEmpty();
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 新歌推荐区域
            _NewSongsSection(
              future: _newSongsFuture,
              player: widget.player,
              auth: widget.auth,
            ),
            // 榜单标题 + 刷新按钮
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 12, 18, 6),
              child: Row(
                children: [
                  const Text(
                    '排行榜',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: '刷新',
                    onPressed: _refresh,
                    icon: const Icon(Icons.refresh_rounded, size: 20),
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
            ),
            // 榜单列表 / 网格
            if (isCarLandscape)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final crossAxisCount = constraints.maxWidth > 600 ? 2 : 1;
                    return GridView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: crossAxisCount,
                        mainAxisSpacing: 10,
                        crossAxisSpacing: 10,
                        childAspectRatio: 3.6,
                      ),
                      itemCount: ranks.length,
                      itemBuilder: (context, index) {
                        final rank = ranks[index];
                        return _RankCard(
                          rank: rank,
                          onTap: () => _openRankDetail(rank),
                        );
                      },
                    );
                  },
                ),
              )
            else
              ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: ranks.length,
                separatorBuilder: (_, _) => const SizedBox(height: 10),
                itemBuilder: (context, index) {
                  final rank = ranks[index];
                  return _RankCard(
                    rank: rank,
                    onTap: () => _openRankDetail(rank),
                  );
                },
              ),
            const SizedBox(height: 166),
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// 新歌推荐
// ---------------------------------------------------------------------------

class _NewSongsSection extends StatelessWidget {
  const _NewSongsSection({
    required this.future,
    required this.player,
    required this.auth,
  });

  final Future<List<Song>>? future;
  final PlayerController player;
  final AuthController auth;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return FutureBuilder<List<Song>>(
      future: future,
      builder: (context, snapshot) {
        final songs = snapshot.data ?? [];
        if (songs.isEmpty && snapshot.connectionState == ConnectionState.waiting) {
          return const SizedBox(
            height: 120,
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          );
        }
        if (songs.isEmpty) return const SizedBox.shrink();

        return Padding(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.fiber_new_rounded, size: 20, color: colorScheme.primary),
                  const SizedBox(width: 6),
                  const Text(
                    '新歌推荐',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
                  ),
                  const Spacer(),
                  IconButton.filledTonal(
                    tooltip: '播放全部',
                    onPressed: () =>
                        player.playSong(songs.first, queue: songs),
                    icon: const Icon(Icons.play_arrow_rounded),
                    style: IconButton.styleFrom(
                      fixedSize: const Size.square(38),
                      shape: const CircleBorder(),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 130,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: songs.length > 10 ? 10 : songs.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 12),
                  itemBuilder: (context, index) {
                    final song = songs[index];
                    return _NewSongCard(
                      song: song,
                      onTap: () => player.playSong(song, queue: songs),
                      isPlaying: player.currentSong?.hash == song.hash &&
                          song.hash.isNotEmpty,
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _NewSongCard extends StatelessWidget {
  const _NewSongCard({
    required this.song,
    required this.onTap,
    required this.isPlaying,
  });

  final Song song;
  final VoidCallback onTap;
  final bool isPlaying;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 100,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Artwork(url: song.coverUrl, size: 100, borderRadius: 10),
            const SizedBox(height: 6),
            Text(
              song.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: isPlaying ? colorScheme.primary : colorScheme.onSurface,
              ),
            ),
            Text(
              song.artist,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 10,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RankCard extends StatelessWidget {
  const _RankCard({required this.rank, required this.onTap});

  final RankCategory rank;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final size = MediaQuery.sizeOf(context);
    final isCarMode =
        size.width > size.height && ThemeController.instance.carModeEnabled;

    final cardPadding = isCarMode ? 14.0 : 10.0;
    final artworkSize = isCarMode ? 88.0 : 72.0;
    final nameFontSize = isCarMode ? 17.0 : 15.0;
    final songFontSize = isCarMode ? 14.0 : 12.0;
    final spacing = isCarMode ? 16.0 : 14.0;
    final maxSongs = isCarMode ? 2 : 3;

    return Material(
      color: isDark
          ? colorScheme.surfaceContainerHighest.withValues(alpha: .42)
          : colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: EdgeInsets.all(cardPadding),
          child: Row(
            children: [
              // 封面
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: SizedBox.square(
                  dimension: artworkSize,
                  child: Artwork(
                    url: rank.imageUrl,
                    size: artworkSize,
                    borderRadius: 10,
                    icon: Icons.leaderboard_rounded,
                  ),
                ),
              ),
              SizedBox(width: spacing),
              // 榜单信息
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      rank.rankName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: nameFontSize,
                        fontWeight: FontWeight.w800,
                        color: colorScheme.onSurface,
                      ),
                    ),
                    if (rank.songs.isNotEmpty) ...[
                      const SizedBox(height: 5),
                      ...rank.songs.take(maxSongs).map(
                            (s) => Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Text(
                                s.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: songFontSize,
                                  color: colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                Icons.chevron_right_rounded,
                size: isCarMode ? 26 : 22,
                color: colorScheme.onSurfaceVariant.withValues(alpha: .5),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 榜单详情（歌曲列表）
// ---------------------------------------------------------------------------

class RankDetailPage extends StatefulWidget {
  const RankDetailPage({
    super.key,
    required this.api,
    required this.auth,
    required this.player,
    required this.rank,
  });

  final MusicApi api;
  final AuthController auth;
  final PlayerController player;
  final RankCategory rank;

  @override
  State<RankDetailPage> createState() => _RankDetailPageState();
}

class _RankDetailPageState extends State<RankDetailPage> {
  final _scrollController = ScrollController();
  final _songs = <Song>[];
  var _page = 1;
  var _hasMore = true;
  var _isLoadingMore = false;
  var _isLoading = true;
  var _isLoadingAllSongs = false;
  var _allSongsLoaded = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // 如果榜单自带歌曲预览，先显示
    if (widget.rank.songs.isNotEmpty) {
      _songs.addAll(widget.rank.songs);
    }
    _scrollController.addListener(_maybeLoadMore);
    _loadInitial();
  }

  @override
  void dispose() {
    _scrollController
      ..removeListener(_maybeLoadMore)
      ..dispose();
    super.dispose();
  }

  Future<void> _loadInitial() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final result = await widget.api.rankAudio(
        rankId: widget.rank.rankId,
        page: 1,
        pageSize: 50,
      );
      if (!mounted) return;
      setState(() {
        _songs
          ..clear()
          ..addAll(result.songs);
        _page = 2;
        _hasMore = result.songs.length >= 50;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  void _maybeLoadMore() {
    if (!_scrollController.hasClients || !_hasMore || _isLoadingMore) return;
    if (_scrollController.position.extentAfter < 400) _loadMore();
  }

  Future<void> _loadMore() async {
    if (_isLoadingMore || !_hasMore) return;
    setState(() => _isLoadingMore = true);
    try {
      final result = await widget.api.rankAudio(
        rankId: widget.rank.rankId,
        page: _page,
        pageSize: 50,
      );
      if (!mounted) return;
      setState(() {
        _songs.addAll(result.songs);
        _page++;
        _hasMore = result.songs.length >= 50;
        _isLoadingMore = false;
      });
    } catch (_) {
      if (mounted) setState(() => _isLoadingMore = false);
    }
  }

  void _playSong(Song song) {
    widget.player.playSong(song, queue: List.of(_songs));
    _expandQueueInBackgroundIfNeeded(startedWith: song);
  }

  void _playAll() {
    if (_songs.isNotEmpty) {
      final first = _songs.first;
      widget.player.playSong(first, queue: List.of(_songs));
      _expandQueueInBackgroundIfNeeded(startedWith: first);
    }
  }

  /// 后台拉取榜单全部分页，并在仍播放本榜单时扩展播放队列（与歌单详情页同款机制）。
  /// 播放立即以已加载列表开始，不阻塞等待；补全完成后静默替换队列，
  /// 避免"播放全部只含首屏 50 首、播完回到第一首"。
  void _expandQueueInBackgroundIfNeeded({required Song startedWith}) {
    if (_allSongsLoaded || !_hasMore) return;
    final startedKey = startedWith.hash.isNotEmpty ? startedWith.hash : startedWith.id;
    if (startedKey.isEmpty) return;
    unawaited(() async {
      await _loadAllSongs();
      if (!mounted) return;
      final current = widget.player.currentSong;
      if (current == null) return;
      final currentKey = current.hash.isNotEmpty ? current.hash : current.id;
      final queueStillOurs = widget.player.queue.any((s) {
        final k = s.hash.isNotEmpty ? s.hash : s.id;
        return k == startedKey;
      });
      // 用户已切到其它来源则不改队列
      if (currentKey != startedKey && !queueStillOurs) return;
      final expanded = List<Song>.of(_songs);
      if (expanded.length <= widget.player.queue.length) return;
      await widget.player.replaceQueue(expanded);
    }());
  }

  Future<void> _loadAllSongs() async {
    if (_isLoadingAllSongs || _allSongsLoaded) return;
    setState(() => _isLoadingAllSongs = true);
    try {
      final allSongs = await widget.api.rankAudioAll(
        rankId: widget.rank.rankId,
      );
      if (!mounted) return;
      setState(() {
        // 增量追加：保留已加载歌曲，仅追加尚未加载的，避免列表滚动位置被重置
        final existingKeys = _songs.map(_songKey).toSet();
        for (final song in allSongs) {
          final key = _songKey(song);
          if (existingKeys.contains(key)) continue;
          _songs.add(song);
          existingKeys.add(key);
        }
        _hasMore = false;
        _allSongsLoaded = true;
        _isLoadingAllSongs = false;
      });
    } catch (_) {
      if (mounted) setState(() => _isLoadingAllSongs = false);
    }
  }

  String _songKey(Song song) =>
      song.hash.isNotEmpty ? song.hash : song.id;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bottomInset = MediaQuery.paddingOf(context).bottom;

    return Scaffold(
      extendBody: true,
      body: Stack(
        children: [
          CustomScrollView(
            controller: _scrollController,
            slivers: [
              SliverAppBar(
                pinned: true,
                expandedHeight: 220,
                surfaceTintColor: Colors.transparent,
                backgroundColor: Theme.of(context).scaffoldBackgroundColor,
                flexibleSpace: FlexibleSpaceBar(
                  title: Text(
                    widget.rank.rankName,
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 16,
                    ),
                  ),
                  background: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (widget.rank.imageUrl != null)
                        Image.network(
                          widget.rank.imageUrl!,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => const SizedBox.shrink(),
                        ),
                      DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.black.withValues(alpha: .1),
                              isDark
                                  ? const Color(0xFF06070A)
                                  : Colors.white,
                            ],
                            stops: const [0.3, 1],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              // 播放全部按钮
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
                  child: Row(
                    children: [
                      FilledButton.icon(
                        onPressed: _playAll,
                        icon: const Icon(Icons.play_arrow_rounded, size: 20),
                        label: Text('播放全部 (${_songs.length})'),
                        style: FilledButton.styleFrom(
                          shape: const StadiumBorder(),
                        ),
                      ),
                      const Spacer(),
                      if (_isLoading)
                        const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                    ],
                  ),
                ),
              ),
              // 歌曲列表
              if (_error != null && _songs.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '加载失败',
                          style: TextStyle(color: colorScheme.onSurfaceVariant),
                        ),
                        const SizedBox(height: 12),
                        FilledButton.tonal(
                          onPressed: _loadInitial,
                          child: const Text('重试'),
                        ),
                      ],
                    ),
                  ),
                )
              else
                SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      if (index >= _songs.length) {
                        return _isLoadingMore
                            ? const Padding(
                                padding: EdgeInsets.all(16),
                                child: Center(
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                ),
                              )
                            : const SizedBox.shrink();
                      }
                      final song = _songs[index];
                      return _RankSongRow(
                        index: index + 1,
                        song: song,
                        onTap: () => _playSong(song),
                        api: widget.api,
                        auth: widget.auth,
                        player: widget.player,
                        queue: _songs,
                      );
                    },
                    childCount: _songs.length + (_hasMore ? 1 : 0),
                  ),
                ),
              const SliverToBoxAdapter(child: SizedBox(height: 166)),
            ],
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: bottomInset + 10,
            child: MiniPlayer(player: widget.player, auth: widget.auth),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 排行榜歌曲行
// ---------------------------------------------------------------------------

class _RankSongRow extends StatelessWidget {
  const _RankSongRow({
    required this.index,
    required this.song,
    required this.onTap,
    required this.api,
    required this.auth,
    required this.player,
    required this.queue,
  });

  final int index;
  final Song song;
  final VoidCallback onTap;
  final MusicApi api;
  final AuthController auth;
  final PlayerController player;
  final List<Song> queue;

  void _showActions(BuildContext context) {
    showSongActionSheet(
      context: context,
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
          onTap: () => showAddToPlaylistSheet(
            context: context,
            auth: auth,
            song: song,
          ),
        ),
        SongSheetAction(
          icon: Icons.person_rounded,
          title: '查看歌手',
          onTap: () {
            final artist = song.artists.firstWhere(
              (a) => a.name.isNotEmpty,
              orElse: () => const ArtistRef(id: '', name: ''),
            );
            if (artist.name.isEmpty) return;
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => ArtistDetailPage(
                  api: api,
                  auth: auth,
                  artist: artist,
                  player: player,
                ),
              ),
            );
          },
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
    final isTop3 = index <= 3;

    return AnimatedBuilder(
      animation: player,
      builder: (context, _) {
        final isPlaying =
            song.hash.isNotEmpty && player.currentSong?.hash == song.hash;

        return InkWell(
          onTap: onTap,
          onLongPress: () => _showActions(context),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Row(
              children: [
                // 排名
                SizedBox(
                  width: 30,
                  child: Text(
                    '$index',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: isTop3 ? 17 : 14,
                      fontWeight: isTop3 ? FontWeight.w900 : FontWeight.w600,
                      color: isTop3
                          ? colorScheme.primary
                          : colorScheme.onSurfaceVariant,
                      fontStyle: isTop3 ? FontStyle.italic : FontStyle.normal,
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                // 封面
                Artwork(url: song.coverUrl, size: 48, borderRadius: 8),
                const SizedBox(width: 12),
                // 歌曲信息
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        song.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: isPlaying
                              ? colorScheme.primary
                              : colorScheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        song.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 4),
                // 播放中指示 / 更多操作按钮
                if (isPlaying)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Icon(
                      Icons.equalizer_rounded,
                      size: 20,
                      color: colorScheme.primary,
                    ),
                  )
                else
                  IconButton(
                    tooltip: '更多',
                    onPressed: () => _showActions(context),
                    icon: Icon(
                      Icons.more_vert_rounded,
                      size: 20,
                      color:
                          colorScheme.onSurfaceVariant.withValues(alpha: .6),
                    ),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// 骨架屏 / 错误 / 空状态
// ---------------------------------------------------------------------------

class _RankSkeleton extends StatelessWidget {
  const _RankSkeleton({this.isCarLandscape = false});

  final bool isCarLandscape;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final placeholder = BoxDecoration(
      color: colorScheme.surfaceContainerHighest.withValues(alpha: .5),
      borderRadius: BorderRadius.circular(10),
    );

    Widget buildItem() => Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            children: [
              Container(width: 72, height: 72, decoration: placeholder),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(width: 120, height: 14, decoration: placeholder),
                    const SizedBox(height: 8),
                    Container(
                        width: double.infinity,
                        height: 10,
                        decoration: placeholder),
                    const SizedBox(height: 6),
                    Container(width: 160, height: 10, decoration: placeholder),
                  ],
                ),
              ),
            ],
          ),
        );

    if (isCarLandscape) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final crossAxisCount = constraints.maxWidth > 600 ? 2 : 1;
            return GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: crossAxisCount,
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                childAspectRatio: 3.6,
              ),
              itemCount: 8,
              itemBuilder: (context, index) => buildItem(),
            );
          },
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: ListView.separated(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: 8,
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (context, index) => buildItem(),
      ),
    );
  }
}

class _RankError extends StatelessWidget {
  const _RankError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 80),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.cloud_off_rounded,
              size: 48,
              color: colorScheme.onSurfaceVariant.withValues(alpha: .5),
            ),
            const SizedBox(height: 12),
            Text(
              '加载失败',
              style: TextStyle(color: colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            FilledButton.tonal(onPressed: onRetry, child: const Text('重试')),
          ],
        ),
      ),
    );
  }
}

class _RankEmpty extends StatelessWidget {
  const _RankEmpty();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 80),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.leaderboard_rounded,
              size: 48,
              color: colorScheme.onSurfaceVariant.withValues(alpha: .5),
            ),
            const SizedBox(height: 12),
            Text(
              '暂无榜单数据',
              style: TextStyle(color: colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
