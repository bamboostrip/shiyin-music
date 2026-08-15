import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../config/app_config.dart';
import '../../controllers/auth_controller.dart';
import '../../controllers/player_controller.dart';
import '../../core/pinyin_utils.dart';
import '../../models/music_models.dart';
import '../../services/cache_service.dart';
import '../../services/music_api.dart';
import '../widgets/app_section.dart';
import '../widgets/artwork.dart';
import '../widgets/import_playlist_sheet.dart';
import '../widgets/mini_player.dart';
import '../widgets/now_playing_badge.dart';
import '../widgets/song_action_sheets.dart';
import '../widgets/toast.dart';
import '../adaptive_layout.dart';
import 'artist_detail_page.dart';

/// 缓存中完整歌单歌曲列表的 key 后缀。
const _fullSongsCacheSuffix = '_full';

class PlaylistDetailPage extends StatefulWidget {
  const PlaylistDetailPage({
    super.key,
    required this.api,
    required this.auth,
    required this.player,
    required this.playlist,
  });

  final MusicApi api;
  final AuthController auth;
  final PlayerController player;
  final PlaylistSummary playlist;

  @override
  State<PlaylistDetailPage> createState() => _PlaylistDetailPageState();
}

class _PlaylistDetailPageState extends State<PlaylistDetailPage> {
  static const _pageSize = 50;

  final _scrollController = ScrollController();
  final _searchController = TextEditingController();
  final _songs = <Song>[];
  final _cache = CacheService();

  PlaylistSummary? _info;
  var _nextPage = 1;
  var _hasMore = true;
  var _isInitialLoading = true;
  var _isLoadingMore = false;
  String? _errorMessage;
  String? _loadMoreError;
  bool _isMutating = false;
  bool _isSearching = false;
  bool _isLoadingAllSongs = false;
  bool _allSongsLoaded = false;
  bool _isSelecting = false;
  bool _selectAllMode = false;
  final Set<String> _selectedKeys = {};
  final Set<String> _excludedKeys = {};
  String _searchQuery = '';
  _SongSortMode _sortMode = _SongSortMode.defaultOrder;

  /// 相似歌单（增强展示，加载失败静默忽略）。
  List<PlaylistSummary> _similarPlaylists = const [];

  /// 多选批量下载进行中。
  bool _isBatchDownloading = false;

  /// 自动定位当前播放歌曲相关状态。
  bool _autoLocateDone = false;
  bool _isLocating = false;
  int? _locateTargetIndex;
  final GlobalKey _locateRowKey = GlobalKey();

  String get _sortModeLabel {
    return switch (_sortMode) {
      _SongSortMode.defaultOrder => '默认排序',
      _SongSortMode.byTitle => '按歌名',
      _SongSortMode.byArtist => '按歌手',
      _SongSortMode.byAlbum => '按专辑',
    };
  }

  Future<void> _showSortSheet(BuildContext context) async {
    final selected = await showModalBottomSheet<_SongSortMode>(
      context: context,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (sheetContext) {
        final colorScheme = Theme.of(sheetContext).colorScheme;
        final options = [
          (_SongSortMode.defaultOrder, '默认排序'),
          (_SongSortMode.byTitle, '按歌名'),
          (_SongSortMode.byArtist, '按歌手'),
          (_SongSortMode.byAlbum, '按专辑'),
        ];
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '排序方式',
                  style: Theme.of(
                    sheetContext,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 12),
                Material(
                  color: colorScheme.surfaceContainer,
                  borderRadius: BorderRadius.circular(16),
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    children: [
                      for (var i = 0; i < options.length; i++) ...[
                        _SortOptionTile(
                          label: options[i].$2,
                          selected: _sortMode == options[i].$1,
                          onTap: () =>
                              Navigator.of(sheetContext).pop(options[i].$1),
                        ),
                        if (i < options.length - 1)
                          Divider(
                            height: 1,
                            indent: 16,
                            color: colorScheme.outlineVariant.withValues(
                              alpha: .3,
                            ),
                          ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (selected != null && selected != _sortMode) {
      setState(() => _sortMode = selected);
    }
  }

  bool get _isAlbum => widget.playlist.isCollectedAlbum;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_maybeLoadMore);
    if (widget.playlist.isLikedPlaylist) {
      widget.auth.addListener(_onLikedChanged);
    }
    _loadInitial();
  }

  @override
  void dispose() {
    if (widget.playlist.isLikedPlaylist) {
      widget.auth.removeListener(_onLikedChanged);
    }
    _scrollController
      ..removeListener(_maybeLoadMore)
      ..dispose();
    _searchController.dispose();
    _songs.clear();
    _info = null;
    super.dispose();
  }

  void _onLikedChanged() {
    if (!mounted) return;
    final before = _songs.length;
    _songs.removeWhere((song) => !widget.auth.isLiked(song));
    if (_songs.length != before) {
      setState(() {});
    }
  }

  List<Song> get _filteredSongs {
    List<Song> list;
    if (_searchQuery.isEmpty) {
      list = List<Song>.of(_songs);
    } else {
      final q = _searchQuery.toLowerCase();
      list = _songs.where((song) {
        return song.title.toLowerCase().contains(q) ||
            song.artist.toLowerCase().contains(q) ||
            (song.albumName?.toLowerCase().contains(q) ?? false);
      }).toList();
    }

    switch (_sortMode) {
      case _SongSortMode.byTitle:
        list.sort((a, b) => PinyinUtils.comparePinyin(a.title, b.title));
        break;
      case _SongSortMode.byArtist:
        list.sort((a, b) => PinyinUtils.comparePinyin(a.artist, b.artist));
        break;
      case _SongSortMode.byAlbum:
        list.sort(
          (a, b) =>
              PinyinUtils.comparePinyin(a.albumName ?? '', b.albumName ?? ''),
        );
        break;
      case _SongSortMode.defaultOrder:
        break;
    }
    return list;
  }

  void _toggleSearch() {
    setState(() {
      _isSearching = !_isSearching;
      if (!_isSearching) {
        _searchQuery = '';
        _searchController.clear();
      }
    });
    if (_isSearching && !_allSongsLoaded) {
      _loadAllSongs();
    }
  }

  Future<void> _loadAllSongs() async {
    if (_isLoadingAllSongs || _allSongsLoaded) return;
    setState(() => _isLoadingAllSongs = true);
    try {
      final id = _isAlbum
          ? (widget.playlist.albumId ?? widget.playlist.id)
          : widget.playlist.id;

      // 优先尝试从完整歌单缓存读取（命中则跳过网络请求）
      final fullCacheKey = _isAlbum
          ? 'cache_album_${widget.playlist.albumId ?? widget.playlist.id}$_fullSongsCacheSuffix'
          : 'cache_playlist_${widget.playlist.id}$_fullSongsCacheSuffix';

      CacheResult<Map<String, dynamic>>? fullCached;
      try {
        fullCached = await _cache.read<Map<String, dynamic>>(
          fullCacheKey,
          decode: (json) => json,
          ttl: AppConfig.playlistDetailTtl,
        );
      } catch (_) {}

      List<Song> allSongs;
      if (fullCached != null) {
        allSongs = (fullCached.data['songs'] as List? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(Song.fromCache)
            .where((song) => song.hash.isNotEmpty)
            .toList();
      } else {
        allSongs = _isAlbum
            ? await widget.api.albumSongs(id, page: 1, pageSize: 5000)
            : await widget.api.playlistSongs(id, fetchAll: true);
        // 写入完整歌单缓存，后续播放可直接复用
        await _cache.write(fullCacheKey, {
          'songs': allSongs.map((s) => s.toCache()).toList(),
        });
      }

      if (!mounted) return;
      setState(() {
        // 增量追加：保留已有歌曲，仅追加尚未加载的歌曲，
        // 避免先清空再重建列表导致滚动位置被强制重置。
        final existingKeys = _songs
            .map(_songKey)
            .where((k) => k.isNotEmpty)
            .toSet();
        for (final song in allSongs) {
          final key = _songKey(song);
          if (key.isEmpty || existingKeys.contains(key)) continue;
          _songs.add(song);
          existingKeys.add(key);
        }
        _allSongsLoaded = true;
        _hasMore = false;
        _isLoadingAllSongs = false;
      });
    } catch (_) {
      if (mounted) setState(() => _isLoadingAllSongs = false);
    }
  }

  /// 当前可播放队列：已加载列表（搜索时为过滤结果）。
  /// 不阻塞等待未分页内容，避免因 count 含无版权曲而误提示「加载完整歌单」。
  List<Song> _playbackQueueNow() {
    if (_searchQuery.isNotEmpty) return _filteredSongs;
    return _songs.where((s) => s.hash.isNotEmpty).toList();
  }

  /// 后台静默补全剩余分页，并在仍播放本列表时扩展队列（无 Toast）。
  void _expandQueueInBackgroundIfNeeded({required Song startedWith}) {
    if (_searchQuery.isNotEmpty) return;
    if (_allSongsLoaded || !_hasMore) return;
    final startedKey = startedWith.hash.isNotEmpty
        ? startedWith.hash
        : startedWith.id;
    unawaited(() async {
      await _loadAllSongs();
      if (!mounted || startedKey.isEmpty) return;
      final current = widget.player.currentSong;
      if (current == null) return;
      final currentKey = current.hash.isNotEmpty ? current.hash : current.id;
      final queueStillOurs = widget.player.queue.any((s) {
        final k = s.hash.isNotEmpty ? s.hash : s.id;
        return k == startedKey;
      });
      // 用户已切到其它来源则不改队列
      if (currentKey != startedKey && !queueStillOurs) return;
      final expanded = _playbackQueueNow();
      if (expanded.length <= widget.player.queue.length) return;
      await widget.player.replaceQueue(expanded);
    }());
  }

  Future<void> _loadInitial() async {
    setState(() {
      _isInitialLoading = true;
      _isLoadingMore = false;
      _errorMessage = null;
      _loadMoreError = null;
      _nextPage = 1;
      _hasMore = true;
      _info = null;
      _songs.clear();
    });

    final cacheKey = _isAlbum
        ? 'cache_album_${widget.playlist.albumId ?? widget.playlist.id}'
        : 'cache_playlist_${widget.playlist.id}';

    // 先读缓存，命中则立即显示
    CacheResult<Map<String, dynamic>>? cached;
    try {
      cached = await _cache.read<Map<String, dynamic>>(
        cacheKey,
        decode: (json) => json,
        ttl: AppConfig.playlistDetailTtl,
      );
    } catch (_) {}
    if (cached != null && mounted) {
      final cacheData = cached.data;
      final infoJson = cacheData['info'];
      setState(() {
        if (infoJson is Map<String, dynamic>) {
          final library =
              widget.auth.findUserPlaylist(widget.playlist) ?? widget.playlist;
          _info = library.mergeWithDetail(PlaylistSummary.fromCache(infoJson));
        }
        _songs.clear();
        _songs.addAll(
          (cacheData['songs'] as List? ?? const [])
              .whereType<Map<String, dynamic>>()
              .map(Song.fromCache)
              .toList(),
        );
        _isInitialLoading = false;
      });
    }

    try {
      if (_isAlbum) {
        final songPage = await widget.api.albumSongPage(
          widget.playlist.albumId ?? widget.playlist.id,
          page: 1,
          pageSize: _pageSize,
        );
        if (!mounted) return;

        setState(() {
          final songs = songPage.songs;
          // 增量替换：仅当网络数据与当前列表不同时才更新，
          // 避免缓存已显示后网络刷新触发 clear+addAll 导致滚动位置重置。
          final changed =
              _songs.length != songs.length || !_listEquals(_songs, songs);
          if (changed) {
            _songs
              ..clear()
              ..addAll(songs);
          }
          _nextPage = 2;
          _hasMore =
              _songs.length < (widget.playlist.songCount ?? 1 << 31) &&
              songPage.rawItemCount == _pageSize;
          if (!_hasMore) {
            _allSongsLoaded = true;
          }
          _isInitialLoading = false;
        });
        await _cache.write(cacheKey, {
          'songs': songPage.songs.map((s) => s.toCache()).toList(),
        });
      } else {
        final results = await Future.wait([
          widget.api.playlistInfo(widget.playlist.id),
          widget.api.playlistSongPage(
            widget.playlist.id,
            page: 1,
            pageSize: _pageSize,
          ),
        ]);
        if (!mounted) return;

        final info = results[0] as PlaylistSummary;
        final songPage = results[1] as SongPage;
        final songs = songPage.songs;
        setState(() {
          // 详情接口可能缺 type/listId；与入口/库内元数据合并，保证 canEdit 正确
          final library =
              widget.auth.findUserPlaylist(widget.playlist) ?? widget.playlist;
          _info = library.mergeWithDetail(info);
          final songs = songPage.songs;
          // 增量替换：仅当网络数据与当前列表不同时才更新，
          // 避免缓存已显示后网络刷新触发 clear+addAll 导致滚动位置重置。
          final changed =
              _songs.length != songs.length || !_listEquals(_songs, songs);
          if (changed) {
            _songs
              ..clear()
              ..addAll(songs);
          }
          _nextPage = 2;
          _hasMore =
              _songs.length < (info.songCount ?? 1 << 31) &&
              songPage.rawItemCount == _pageSize;
          if (!_hasMore) {
            _allSongsLoaded = true;
          }
          _isInitialLoading = false;
        });
        await _cache.write(cacheKey, {
          'info': info.toCache(),
          'songs': songs.map((s) => s.toCache()).toList(),
        });
      }
    } catch (error) {
      if (!mounted) return;
      if (cached == null) {
        setState(() {
          _errorMessage = error.toString();
          _isInitialLoading = false;
        });
        return;
      }
      // 有缓存数据，保持不报错（降级），继续走相似歌单/自动定位。
    }
    unawaited(_loadSimilarPlaylists());
    if (widget.player.currentSong != null && _errorMessage == null) {
      unawaited(_autoLocateCurrentSong());
    }
  }

  /// 加载相似歌单（增强展示，失败静默忽略）。
  Future<void> _loadSimilarPlaylists() async {
    try {
      final similar = await widget.api.similarPlaylists(widget.playlist.id);
      if (!mounted || similar.isEmpty) return;
      setState(() => _similarPlaylists = similar);
    } catch (_) {}
  }

  /// 打开相似歌单详情。
  void _openSimilarPlaylist(PlaylistSummary playlist) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlaylistDetailPage(
          api: widget.api,
          auth: widget.auth,
          player: widget.player,
          playlist: playlist,
        ),
      ),
    );
  }

  void _maybeLoadMore() {
    if (!_scrollController.hasClients || !_hasMore || _isLoadingMore) {
      return;
    }

    final position = _scrollController.position;
    if (position.extentAfter < 520) {
      _loadMore();
    }
  }

  /// 比较两份歌曲列表是否内容一致（按 hash 逐项比较）。
  bool _listEquals(List<Song> a, List<Song> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].hash != b[i].hash) return false;
    }
    return true;
  }

  Future<void> _loadMore() async {
    if (_isLoadingMore || !_hasMore) return;

    setState(() {
      _isLoadingMore = true;
      _loadMoreError = null;
    });

    try {
      final songPage = _isAlbum
          ? await widget.api.albumSongPage(
              widget.playlist.albumId ?? widget.playlist.id,
              page: _nextPage,
              pageSize: _pageSize,
            )
          : await widget.api.playlistSongPage(
              widget.playlist.id,
              page: _nextPage,
              pageSize: _pageSize,
            );
      if (!mounted) return;

      setState(() {
        final songs = songPage.songs;
        _songs.addAll(songs);
        _nextPage++;
        _hasMore =
            songPage.rawItemCount == _pageSize &&
            _songs.length < (_currentPlaylist.songCount ?? 1 << 31);
        if (!_hasMore) {
          _allSongsLoaded = true;
        }
        _isLoadingMore = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadMoreError = error.toString();
        _isLoadingMore = false;
      });
    }
  }

  /// 打开页面时自动定位到当前播放的歌曲（滚动到其所在行）。
  ///
  /// 当前歌曲尚未加载（分页懒加载）时：若播放队列与当前歌单匹配
  /// （已加载歌曲全部属于当前队列），逐页加载直到找到；否则不再额外请求，
  /// 避免打开任意歌单都触发全量加载。
  Future<void> _autoLocateCurrentSong() async {
    if (_autoLocateDone || _isLocating) return;
    final current = widget.player.currentSong;
    if (current == null) return;
    _autoLocateDone = true;
    _isLocating = true;
    try {
      var index = _filteredSongs.indexWhere((s) => s.hash == current.hash);
      if (index < 0 && _queueMatchesThisPlaylist()) {
        // 逐页加载直到找到（上限 24 页，异常情况不再继续）
        var pages = 0;
        while (index < 0 &&
            pages++ < 24 &&
            _hasMore &&
            _loadMoreError == null) {
          await _loadMore();
          if (!mounted) return;
          index = _filteredSongs.indexWhere((s) => s.hash == current.hash);
        }
      }
      if (index >= 0 && mounted) {
        await _scrollToSong(index);
      }
    } finally {
      _isLocating = false;
    }
  }

  /// 当前播放队列是否「像」来自本歌单：已加载歌曲全部属于当前队列。
  ///
  /// 在本歌单内点播放时队列即完整歌单，此判断可避免在其他歌单页面
  /// 触发无意义的全量加载。
  bool _queueMatchesThisPlaylist() {
    final queueHashes = widget.player.queue.map((s) => s.hash).toSet();
    if (queueHashes.isEmpty || _songs.isEmpty) return false;
    return _songs.every((s) => queueHashes.contains(s.hash));
  }

  /// 滚动到展示列表中 [displayIndex] 所在行：先按固定行高估算偏移跳转，
  /// 再用目标行 key 精确校正（兼容字体缩放等导致的估算误差）。
  Future<void> _scrollToSong(int displayIndex) async {
    if (displayIndex < 0 || displayIndex >= _filteredSongs.length) return;
    if (!_scrollController.hasClients) {
      // 等待首帧布局完成（内容刚加载完时 ScrollView 可能尚未 attach）
      for (var i = 0; i < 20 && !_scrollController.hasClients && mounted; i++) {
        await WidgetsBinding.instance.endOfFrame;
      }
      if (!mounted || !_scrollController.hasClients) return;
    }

    final topInset = MediaQuery.paddingOf(context).top;
    // 折叠后 SliverAppBar 工具栏高度 + _Actions 操作行（含 padding）+
    // 列表顶部 padding；歌曲行高 68 + 分隔 2。
    const actionsHeight = 70.0;
    const listTopPadding = 4.0;
    const rowExtent = 70.0;
    final targetOffset =
        kToolbarHeight +
        topInset +
        actionsHeight +
        listTopPadding +
        displayIndex * rowExtent;

    setState(() => _locateTargetIndex = displayIndex);

    final position = _scrollController.position;
    _scrollController.jumpTo(targetOffset.clamp(0.0, position.maxScrollExtent));

    // 精确校正：定位行 key 一旦构建，用 ensureVisible 对齐到视口上 1/4 处。
    // 估算偏移与真实偏移存在误差（字体缩放等）时，向后/向前各探测一屏。
    var probe = 0; // 0=未探测 1=已向后探测 2=已双向探测
    for (var attempt = 0; attempt < 10; attempt++) {
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      final rowContext = _locateRowKey.currentContext;
      if (rowContext != null && rowContext.mounted) {
        await Scrollable.ensureVisible(
          rowContext,
          alignment: 0.25,
          duration: const Duration(milliseconds: 220),
        );
        if (mounted) setState(() => _locateTargetIndex = null);
        return;
      }
      final currentPosition = _scrollController.position;
      final remaining = targetOffset - currentPosition.pixels;
      if (remaining.abs() > 4) {
        // 尚未到达估算位置：直接跳到估算偏移
        _scrollController.jumpTo(
          (currentPosition.pixels + remaining).clamp(
            0.0,
            currentPosition.maxScrollExtent,
          ),
        );
        continue;
      }
      if (probe == 0) {
        probe = 1;
        _scrollController.jumpTo(
          (currentPosition.pixels - currentPosition.viewportDimension * 0.9)
              .clamp(0.0, currentPosition.maxScrollExtent),
        );
      } else if (probe == 1) {
        probe = 2;
        _scrollController.jumpTo(
          (currentPosition.pixels + currentPosition.viewportDimension * 0.9)
              .clamp(0.0, currentPosition.maxScrollExtent),
        );
      } else {
        break;
      }
    }
    if (mounted) setState(() => _locateTargetIndex = null);
  }

  PlaylistSummary get _currentPlaylist => _info ?? widget.playlist;

  PlaylistSummary get _libraryPlaylist {
    return widget.auth.findUserPlaylist(_currentPlaylist) ?? _currentPlaylist;
  }

  bool get _isInLibrary => widget.auth.isPlaylistInLibrary(_currentPlaylist);

  /// 优先用库列表里的歌单元数据判断，避免详情接口字段不全导致无法删歌。
  bool get _canEdit => widget.auth.canEditPlaylist(_libraryPlaylist);

  String _songKey(Song song) => song.hash.isNotEmpty ? song.hash : song.id;

  bool _isSongSelected(Song song) {
    final key = _songKey(song);
    if (key.isEmpty) return false;
    if (_selectAllMode) {
      return !_excludedKeys.contains(key);
    }
    return _selectedKeys.contains(key);
  }

  int get _selectedCount {
    if (!_isSelecting) return 0;
    if (_selectAllMode) {
      // 未全部加载时用歌单总数估算，避免全选后显示偏小
      if (_searchQuery.isEmpty &&
          !_allSongsLoaded &&
          _currentPlaylist.songCount != null) {
        return (_currentPlaylist.songCount! - _excludedKeys.length).clamp(
          0,
          _currentPlaylist.songCount!,
        );
      }
      final pool = _selectPool;
      return pool.where((s) => !_excludedKeys.contains(_songKey(s))).length;
    }
    return _selectedKeys.length;
  }

  /// 当前可选池：搜索时为过滤结果，否则为已加载列表。
  List<Song> get _selectPool => _filteredSongs;

  bool get _isAllSelected {
    final pool = _selectPool;
    if (pool.isEmpty) return false;
    if (_selectAllMode) {
      return pool.every((s) => !_excludedKeys.contains(_songKey(s)));
    }
    return pool.every((s) => _selectedKeys.contains(_songKey(s)));
  }

  void _enterSelectMode() {
    setState(() {
      _isSelecting = true;
      _selectAllMode = false;
      _selectedKeys.clear();
      _excludedKeys.clear();
      if (_isSearching) {
        _isSearching = false;
        _searchQuery = '';
        _searchController.clear();
      }
    });
  }

  void _exitSelectMode() {
    setState(() {
      _isSelecting = false;
      _selectAllMode = false;
      _selectedKeys.clear();
      _excludedKeys.clear();
    });
  }

  void _toggleSongSelection(Song song) {
    final key = _songKey(song);
    if (key.isEmpty) return;
    setState(() {
      if (_selectAllMode) {
        if (_excludedKeys.contains(key)) {
          _excludedKeys.remove(key);
        } else {
          _excludedKeys.add(key);
        }
      } else {
        if (_selectedKeys.contains(key)) {
          _selectedKeys.remove(key);
        } else {
          _selectedKeys.add(key);
        }
      }
    });
  }

  void _toggleSelectAll() {
    setState(() {
      if (_isAllSelected) {
        _selectAllMode = false;
        _selectedKeys.clear();
        _excludedKeys.clear();
      } else {
        // 逻辑全选：只标记模式，不把所有 id 塞进 Set
        _selectAllMode = true;
        _selectedKeys.clear();
        _excludedKeys.clear();
      }
    });
  }

  Future<List<Song>> _resolveSelectedSongs() async {
    // 仅当真有未加载分页时才补全；count 含无版权曲时不再误触发
    if (_selectAllMode &&
        _searchQuery.isEmpty &&
        !_allSongsLoaded &&
        _hasMore) {
      Toast.info('正在加载完整列表…');
      await _loadAllSongs();
      if (!_allSongsLoaded) {
        Toast.error('完整歌单加载失败，仅对已加载的歌曲生效');
      }
    }
    final pool = _selectPool;
    if (_selectAllMode) {
      return pool.where((s) => !_excludedKeys.contains(_songKey(s))).toList();
    }
    return pool.where((s) => _selectedKeys.contains(_songKey(s))).toList();
  }

  Future<void> _batchPlayNext() async {
    final songs = await _resolveSelectedSongs();
    if (songs.isEmpty || !mounted) return;
    try {
      final n = await widget.player.addSongsToQueue(songs);
      Toast.success(n > 0 ? '已添加 $n 首到下一首播放' : '所选歌曲已在播放中');
      _exitSelectMode();
    } catch (e) {
      Toast.error('添加失败：$e');
    }
  }

  Future<void> _batchAddToPlaylist() async {
    final songs = await _resolveSelectedSongs();
    if (songs.isEmpty || !mounted) return;
    final ok = await showAddSongsToPlaylistSheet(
      context: context,
      auth: widget.auth,
      songs: songs,
    );
    if (ok && mounted) _exitSelectMode();
  }

  Future<void> _batchDelete() async {
    if (!_canEdit) return;
    final songs = await _resolveSelectedSongs();
    if (songs.isEmpty || !mounted) return;
    final confirmed = await _confirm(
      title: '删除歌曲',
      message: '从当前歌单删除选中的 ${songs.length} 首歌曲？',
    );
    if (confirmed != true) return;
    await _runMutation(() async {
      await widget.auth.removeSongsFromPlaylist(_libraryPlaylist, songs);
      if (!mounted) return;
      final keys = songs.map(_songKey).toSet();
      setState(() {
        _songs.removeWhere((s) => keys.contains(_songKey(s)));
      });
      _exitSelectMode();
    });
  }

  /// 把选中的歌曲批量加入下载队列。
  Future<void> _batchDownload() async {
    final downloads = widget.player.downloadController;
    if (downloads == null) {
      Toast.error('下载功能不可用');
      return;
    }
    if (_isBatchDownloading) return;
    // 先置位再解析歌曲，避免加载完整列表期间重复点击并发入队。
    setState(() => _isBatchDownloading = true);
    final songs = await _resolveSelectedSongs();
    if (songs.isEmpty || !mounted) {
      if (mounted) setState(() => _isBatchDownloading = false);
      return;
    }

    try {
      final result = await downloads.enqueueBatch(
        songs,
        widget.player.audioQuality,
      );
      final parts = <String>['已加入下载队列 ${result.enqueued} 首'];
      if (result.skipped > 0) {
        parts.add('已跳过 ${result.skipped} 首（已下载/下载中）');
      }
      if (result.failed > 0) {
        parts.add('失败 ${result.failed} 首');
      }
      Toast.success(parts.join('，'));
    } catch (_) {
      Toast.error('加入下载队列失败');
    } finally {
      if (mounted) {
        setState(() => _isBatchDownloading = false);
        _exitSelectMode();
      }
    }
  }

  Future<void> _collectPlaylist() async {
    if (_isAlbum) return;
    await _runMutation(() => widget.auth.collectPlaylist(_currentPlaylist));
  }

  Future<void> _deleteOrUncollectPlaylist() async {
    final target = _libraryPlaylist;
    final title = target.isCollectedAlbum
        ? '取消收藏专辑'
        : target.isCreatedPlaylist
        ? '删除歌单'
        : '取消收藏';
    final message = target.isCollectedAlbum
        ? '确定要取消收藏这个专辑吗？'
        : target.isCreatedPlaylist
        ? '确定要删除这个歌单吗？'
        : '确定要取消收藏这个歌单吗？';
    final confirmed = await _confirm(title: title, message: message);
    if (confirmed != true) return;

    await _runMutation(() => widget.auth.deleteOrUncollectPlaylist(target));
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _removeSong(Song song) async {
    final confirmed = await _confirm(title: '删除歌曲', message: '从当前歌单删除这首歌？');
    if (confirmed != true) return;
    await _runMutation(() async {
      await widget.auth.removeSongFromPlaylist(_libraryPlaylist, song);
      if (mounted) {
        setState(() => _songs.removeWhere((item) => item.id == song.id));
      }
    });
  }

  Future<void> _addSongToPlaylist(Song song) async {
    await showAddToPlaylistSheet(
      context: context,
      auth: widget.auth,
      song: song,
    );
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

  /// 分享歌单：将歌单信息与歌曲列表复制到剪贴板。
  void _sharePlaylist() {
    final info = _currentPlaylist;
    final songs = _songs;
    final buffer = StringBuffer();
    buffer.writeln('🎵 ${info.title}');
    if (info.subtitle != null && info.subtitle!.trim().isNotEmpty) {
      buffer.writeln('by ${info.subtitle}');
    }
    buffer.writeln('共 ${songs.length} 首');
    buffer.writeln('---');
    for (var i = 0; i < songs.length; i++) {
      final song = songs[i];
      buffer.writeln('${i + 1}. ${song.title} - ${song.artist}');
    }
    Clipboard.setData(ClipboardData(text: buffer.toString()));
    Toast.success('歌单信息已复制到剪贴板');
  }

  /// 显示歌单操作 BottomSheet（收藏/删除/取消收藏）。
  void _showPlaylistActionSheet() {
    final options = <_ActionOption>[];
    if (!_isAlbum && !_isInLibrary) {
      options.add(
        _ActionOption(
          icon: Icons.bookmark_add_outlined,
          title: '收藏歌单',
          onTap: _collectPlaylist,
        ),
      );
    }
    if (_isInLibrary &&
        !_libraryPlaylist.isLikedPlaylist &&
        !_libraryPlaylist.isSystemDefaultCollect) {
      final isAlbum = _libraryPlaylist.isCollectedAlbum;
      final isCreated = _libraryPlaylist.isCreatedPlaylist;
      options.add(
        _ActionOption(
          icon: isCreated
              ? Icons.delete_outline_rounded
              : Icons.bookmark_remove_outlined,
          title: isAlbum
              ? '取消收藏专辑'
              : isCreated
              ? '删除歌单'
              : '取消收藏',
          danger: isCreated,
          onTap: _deleteOrUncollectPlaylist,
        ),
      );
    }
    if (options.isEmpty) return;

    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (sheetContext) {
        final colorScheme = Theme.of(sheetContext).colorScheme;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '歌单操作',
                  style: Theme.of(
                    sheetContext,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 12),
                Material(
                  color: colorScheme.surfaceContainer,
                  borderRadius: BorderRadius.circular(16),
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    children: [
                      for (var i = 0; i < options.length; i++) ...[
                        _ActionOptionTile(option: options[i]),
                        if (i < options.length - 1)
                          Divider(
                            height: 1,
                            indent: 58,
                            color: colorScheme.outlineVariant.withValues(
                              alpha: .3,
                            ),
                          ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 通过歌单 ID 导入并打开歌单详情。
  /// 公开静态 API，供外部调用。
  // ignore: unused_element
  static Future<void> importPlaylistById({
    required BuildContext context,
    required MusicApi api,
    required AuthController auth,
    required PlayerController player,
    required String playlistId,
  }) async {
    Toast.info('正在导入歌单...');
    try {
      final info = await api.playlistInfo(playlistId);
      if (!context.mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => PlaylistDetailPage(
            api: api,
            auth: auth,
            player: player,
            playlist: info,
          ),
        ),
      );
    } catch (e) {
      if (context.mounted) Toast.error('导入失败：$e');
    }
  }

  Future<void> _runMutation(Future<void> Function() action) async {
    if (_isMutating) return;
    setState(() => _isMutating = true);
    try {
      await action();
      if (widget.auth.errorMessage != null) {
        throw Exception(widget.auth.errorMessage);
      }
      Toast.success('操作完成');
    } catch (error) {
      Toast.error('操作失败：$error');
    } finally {
      if (mounted) {
        setState(() => _isMutating = false);
      }
    }
  }

  Future<bool?> _confirm({required String title, required String message}) {
    return showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('确定'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.paddingOf(context).bottom;

    return PopScope(
      canPop: !_isSelecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _isSelecting) {
          _exitSelectMode();
        }
      },
      child: Scaffold(
        extendBody: true,
        body: AdaptiveContentPadding(
          child: Stack(
            children: [
              // Windows 平台滚动时 sliver item 回收重建会产生大量语义节点更新，
              // 触发 Flutter Windows 引擎 AXTree 更新 bug（console 提示
              // "Failed to update ui::AXTree"）。在 Windows 上排除语义树消除提示，
              // 移动端保留无障碍功能。
              ExcludeSemantics(
                excluding: !Platform.isWindows,
                child: CustomScrollView(
                  controller: _scrollController,
                  slivers: [
                    SliverAppBar(
                      pinned: true,
                      stretch: !_isSearching,
                      expandedHeight: _isSearching ? 0 : 198,
                      surfaceTintColor: Colors.transparent,
                      // 头部渐变顶部为半透明 primary，收缩后若 toolbar 无不透明背景，
                      // 列表内容会透过与标题/操作按钮重叠。这里用 scaffoldBackgroundColor
                      // 作为不透明底色（与头部渐变底部一致，过渡自然），展开态被 _HeroHeader 覆盖。
                      backgroundColor: Theme.of(
                        context,
                      ).scaffoldBackgroundColor,
                      leading: _isSelecting
                          ? IconButton(
                              tooltip: '取消',
                              onPressed: _exitSelectMode,
                              icon: const Icon(Icons.close_rounded),
                            )
                          : null,
                      title: _isSelecting
                          ? Text(
                              '已选 $_selectedCount 首',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w800,
                              ),
                            )
                          : _isSearching
                          ? TextField(
                              controller: _searchController,
                              autofocus: true,
                              onChanged: (value) =>
                                  setState(() => _searchQuery = value),
                              decoration: InputDecoration(
                                hintText: _isLoadingAllSongs
                                    ? '正在加载全部歌曲…'
                                    : '搜索歌曲名或歌手名',
                                border: InputBorder.none,
                                hintStyle: TextStyle(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                ),
                              ),
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            )
                          : Text(
                              (_info ?? widget.playlist).title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                      actions: [
                        if (_isSelecting) ...[
                          TextButton(
                            onPressed: _selectPool.isEmpty
                                ? null
                                : _toggleSelectAll,
                            child: Text(_isAllSelected ? '取消全选' : '全选'),
                          ),
                        ] else if (!_isSearching) ...[
                          IconButton(
                            tooltip: '选择',
                            onPressed: _songs.isEmpty && !_hasMore
                                ? null
                                : _enterSelectMode,
                            icon: const Icon(Icons.checklist_rounded),
                          ),
                          IconButton(
                            tooltip: '搜索',
                            onPressed: _toggleSearch,
                            icon: const Icon(Icons.search_rounded),
                          ),
                          IconButton(
                            tooltip: '分享',
                            onPressed: _sharePlaylist,
                            icon: const Icon(Icons.share_rounded),
                          ),
                          IconButton(
                            tooltip: '导入歌单',
                            onPressed: () => showImportPlaylistSheet(
                              context: context,
                              api: widget.api,
                              auth: widget.auth,
                            ),
                            icon: const Icon(Icons.playlist_add_rounded),
                          ),
                          if (_isMutating)
                            const Padding(
                              padding: EdgeInsets.only(right: 16),
                              child: Center(
                                child: SizedBox.square(
                                  dimension: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.2,
                                  ),
                                ),
                              ),
                            )
                          else if ((!_isAlbum && !_isInLibrary) ||
                              (_isInLibrary &&
                                  !_libraryPlaylist.isLikedPlaylist))
                            IconButton(
                              tooltip: '更多',
                              onPressed: _showPlaylistActionSheet,
                              icon: const Icon(Icons.more_vert_rounded),
                            ),
                        ] else
                          IconButton(
                            tooltip: '关闭搜索',
                            onPressed: _toggleSearch,
                            icon: const Icon(Icons.close_rounded),
                          ),
                      ],
                      flexibleSpace: _isSearching
                          ? null
                          : FlexibleSpaceBar(
                              stretchModes: const [StretchMode.zoomBackground],
                              background: _HeroHeader(
                                info: _info ?? widget.playlist,
                              ),
                            ),
                    ),
                    if (_isInitialLoading)
                      const _PlaylistDetailSkeleton()
                    else if (_errorMessage case final message?)
                      SliverFillRemaining(
                        hasScrollBody: false,
                        child: _DetailError(
                          title: _isAlbum ? '专辑加载失败' : '歌单加载失败',
                          message: message,
                          onRetry: _loadInitial,
                        ),
                      )
                    else ...[
                      if (!_isSelecting)
                        SliverToBoxAdapter(
                          child: _Actions(
                            // 以可播放列表为准；元数据 count 可能含无版权曲
                            count: (!_hasMore || _allSongsLoaded)
                                ? _songs.length
                                : (_info?.songCount ?? _songs.length),
                            loadedCount: _songs.length,
                            sortLabel: _sortModeLabel,
                            onSortTap: () => _showSortSheet(context),
                            onPlay: _playbackQueueNow().isEmpty
                                ? null
                                : () {
                                    final queue = _playbackQueueNow();
                                    if (queue.isEmpty) return;
                                    final first = queue.first;
                                    widget.player.playSong(
                                      first,
                                      queue: List<Song>.of(queue),
                                    );
                                    _expandQueueInBackgroundIfNeeded(
                                      startedWith: first,
                                    );
                                  },
                            searchQuery: _searchQuery,
                            searchResultCount: _searchQuery.isNotEmpty
                                ? _filteredSongs.length
                                : null,
                          ),
                        ),
                      if (_isLoadingAllSongs)
                        const SliverToBoxAdapter(
                          child: Padding(
                            padding: EdgeInsets.symmetric(vertical: 40),
                            child: Center(
                              child: Column(
                                children: [
                                  CircularProgressIndicator(strokeWidth: 2.4),
                                  SizedBox(height: 12),
                                  Text('正在加载全部歌曲…'),
                                ],
                              ),
                            ),
                          ),
                        )
                      else if (_searchQuery.isNotEmpty &&
                          _filteredSongs.isEmpty)
                        const SliverToBoxAdapter(child: _SearchEmpty())
                      else ...[
                        SliverPadding(
                          padding: EdgeInsets.fromLTRB(
                            12,
                            4,
                            12,
                            _isSelecting ? 100 : 12,
                          ),
                          sliver: SliverList.separated(
                            itemCount: _filteredSongs.length,
                            separatorBuilder: (_, _) =>
                                const SizedBox(height: 2),
                            itemBuilder: (context, index) {
                              final song = _filteredSongs[index];
                              return _SongRow(
                                key: _locateTargetIndex == index
                                    ? _locateRowKey
                                    : null,
                                song: song,
                                index: index + 1,
                                player: widget.player,
                                canDelete: _canEdit,
                                selecting: _isSelecting,
                                selected: _isSongSelected(song),
                                onTap: () {
                                  if (_isSelecting) {
                                    _toggleSongSelection(song);
                                    return;
                                  }
                                  final queue = _playbackQueueNow();
                                  if (queue.isEmpty) return;
                                  widget.player.playSong(
                                    song,
                                    queue: List<Song>.of(queue),
                                  );
                                  _expandQueueInBackgroundIfNeeded(
                                    startedWith: song,
                                  );
                                },
                                onAddToPlaylist: () => _addSongToPlaylist(song),
                                onDelete: () => _removeSong(song),
                                onViewArtist: () => _openArtist(song),
                              );
                            },
                          ),
                        ),
                        if (_searchQuery.isEmpty)
                          SliverToBoxAdapter(
                            child: _LoadMoreFooter(
                              hasMore: _hasMore,
                              isLoading: _isLoadingMore,
                              errorMessage: _loadMoreError,
                              onRetry: _loadMore,
                            ),
                          ),
                        if (_searchQuery.isEmpty &&
                            _similarPlaylists.isNotEmpty)
                          SliverToBoxAdapter(
                            child: _SimilarPlaylistsSection(
                              playlists: _similarPlaylists,
                              onTap: _openSimilarPlaylist,
                            ),
                          ),
                      ],
                    ],
                  ],
                ),
              ),
              if (_isSelecting)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: _SelectionBottomBar(
                    canDelete: _canEdit,
                    downloading: _isBatchDownloading,
                    onPlayNext: _selectedCount > 0 ? _batchPlayNext : null,
                    onAddToPlaylist: _selectedCount > 0
                        ? _batchAddToPlaylist
                        : null,
                    onDownload: _selectedCount > 0 && !_isBatchDownloading
                        ? _batchDownload
                        : null,
                    onDelete: _canEdit && _selectedCount > 0
                        ? _batchDelete
                        : null,
                  ),
                )
              else
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: bottomInset + 10,
                  child: MiniPlayer(player: widget.player, auth: widget.auth),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 相似歌单横向区块。
class _SimilarPlaylistsSection extends StatelessWidget {
  const _SimilarPlaylistsSection({
    required this.playlists,
    required this.onTap,
  });

  final List<PlaylistSummary> playlists;
  final ValueChanged<PlaylistSummary> onTap;

  @override
  Widget build(BuildContext context) {
    return AppHorizontalRail<PlaylistSummary>(
      title: '相似歌单',
      items: playlists,
      height: 170,
      itemWidth: 120,
      topPadding: 20,
      itemBuilder: (context, playlist) => _SimilarPlaylistCard(
        playlist: playlist,
        onTap: () => onTap(playlist),
      ),
    );
  }
}

class _SimilarPlaylistCard extends StatelessWidget {
  const _SimilarPlaylistCard({required this.playlist, required this.onTap});

  final PlaylistSummary playlist;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        width: 120,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Artwork(url: playlist.coverUrl, size: 120),
            ),
            const SizedBox(height: 6),
            Text(
              playlist.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
            ),
            Text(
              playlist.creatorName ?? '',
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
    );
  }
}

class _SelectionBottomBar extends StatelessWidget {
  const _SelectionBottomBar({
    required this.canDelete,
    required this.downloading,
    required this.onPlayNext,
    required this.onAddToPlaylist,
    required this.onDownload,
    required this.onDelete,
  });

  final bool canDelete;
  final bool downloading;
  final VoidCallback? onPlayNext;
  final VoidCallback? onAddToPlaylist;
  final VoidCallback? onDownload;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final bottom = MediaQuery.paddingOf(context).bottom;
    return Material(
      elevation: 8,
      color: colorScheme.surface,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.fromLTRB(12, 10, 12, bottom > 0 ? 8 : 12),
          child: Row(
            children: [
              Expanded(
                child: _SelectionActionButton(
                  icon: Icons.queue_music_rounded,
                  label: '下一首',
                  onTap: onPlayNext,
                ),
              ),
              Expanded(
                child: _SelectionActionButton(
                  icon: Icons.playlist_add_rounded,
                  label: '加歌单',
                  onTap: onAddToPlaylist,
                ),
              ),
              Expanded(
                child: _SelectionActionButton(
                  icon: Icons.download_rounded,
                  label: downloading ? '加入中…' : '下载',
                  busy: downloading,
                  onTap: onDownload,
                ),
              ),
              if (canDelete)
                Expanded(
                  child: _SelectionActionButton(
                    icon: Icons.delete_outline_rounded,
                    label: '删除',
                    danger: true,
                    onTap: onDelete,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SelectionActionButton extends StatelessWidget {
  const _SelectionActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.danger = false,
    this.busy = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool danger;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final color = onTap == null
        ? colorScheme.onSurface.withValues(alpha: .38)
        : danger
        ? colorScheme.error
        : colorScheme.onSurface;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (busy)
              SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2.4,
                  color: color,
                ),
              )
            else
              Icon(icon, color: color, size: 24),
            const SizedBox(height: 4),
            Text(
              label,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: color,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 歌单操作选项数据。
class _ActionOption {
  const _ActionOption({
    required this.icon,
    required this.title,
    required this.onTap,
    this.danger = false,
  });

  final IconData icon;
  final String title;
  final VoidCallback onTap;
  final bool danger;
}

/// 歌单操作选项条目。
class _ActionOptionTile extends StatelessWidget {
  const _ActionOptionTile({required this.option});

  final _ActionOption option;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final color = option.danger ? colorScheme.error : colorScheme.onSurface;
    return InkWell(
      onTap: () {
        Navigator.of(context).pop();
        option.onTap();
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Icon(option.icon, size: 22, color: color),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                option.title,
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HeroHeader extends StatelessWidget {
  const _HeroHeader({required this.info});

  final PlaylistSummary info;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            colorScheme.primary.withValues(alpha: isDark ? .28 : .18),
            const Color(0xFFDCEEFF).withValues(alpha: isDark ? .08 : .92),
            Theme.of(context).scaffoldBackgroundColor,
          ],
          stops: const [0, .58, 1],
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth < 380;
              final artworkSize = compact ? 90.0 : 102.0;

              return Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Artwork(
                    url: info.coverUrl,
                    size: artworkSize,
                    borderRadius: 16,
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Text(
                          info.title,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(
                                fontSize: 18,
                                fontWeight: FontWeight.w900,
                                height: 1.05,
                              ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          info.subtitle?.trim().isNotEmpty == true
                              ? info.subtitle!
                              : _detailMeta(info),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(
                                color: colorScheme.onSurfaceVariant,
                                fontWeight: FontWeight.w600,
                              ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          _detailMeta(info),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: colorScheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _PlaylistDetailSkeleton extends StatelessWidget {
  const _PlaylistDetailSkeleton();

  @override
  Widget build(BuildContext context) {
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 118),
      sliver: SliverList.list(
        children: [
          Row(
            children: [
              const _SkeletonBox(width: 108, height: 18, radius: 7),
              const Spacer(),
              _SkeletonBox(width: 104, height: 40, radius: 20),
            ],
          ),
          const SizedBox(height: 20),
          for (var index = 0; index < 10; index++) ...[
            const _PlaylistSkeletonSongRow(),
            const SizedBox(height: 18),
          ],
        ],
      ),
    );
  }
}

class _PlaylistSkeletonSongRow extends StatelessWidget {
  const _PlaylistSkeletonSongRow();

  @override
  Widget build(BuildContext context) {
    return const Row(
      children: [
        _SkeletonBox(width: 50, height: 50, radius: 9),
        SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _SkeletonBox(width: double.infinity, height: 16, radius: 6),
              SizedBox(height: 8),
              _SkeletonBox(width: 142, height: 14, radius: 6),
            ],
          ),
        ),
        SizedBox(width: 12),
        _SkeletonBox(width: 38, height: 14, radius: 6),
        SizedBox(width: 18),
        _SkeletonBox(width: 24, height: 24, radius: 12),
      ],
    );
  }
}

class _SkeletonBox extends StatelessWidget {
  const _SkeletonBox({
    required this.width,
    required this.height,
    required this.radius,
  });

  final double width;
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: .72),
        borderRadius: BorderRadius.circular(radius),
      ),
      child: SizedBox(width: width, height: height),
    );
  }
}

class _Actions extends StatelessWidget {
  const _Actions({
    required this.count,
    required this.loadedCount,
    required this.onPlay,
    required this.sortLabel,
    required this.onSortTap,
    this.searchQuery,
    this.searchResultCount,
  });

  final int count;
  final int loadedCount;
  final VoidCallback? onPlay;
  final String? searchQuery;
  final int? searchResultCount;
  final String sortLabel;
  final VoidCallback onSortTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isSearching = searchQuery != null && searchQuery!.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 12),
      child: Row(
        children: [
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    isSearching
                        ? '搜索结果：$searchResultCount 首'
                        : loadedCount >= count
                        ? '$count 首歌曲'
                        : '已加载 $loadedCount / $count 首',
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w700,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (!isSearching) ...[
                  const SizedBox(width: 8),
                  TextButton.icon(
                    onPressed: onSortTap,
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    icon: const Icon(Icons.sort_rounded, size: 16),
                    label: Text(
                      sortLabel,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: colorScheme.primary,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (!isSearching)
            FilledButton.icon(
              onPressed: onPlay,
              icon: const Icon(Icons.play_arrow_rounded),
              label: const Text('播放全部'),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 18),
                shape: const StadiumBorder(),
              ),
            )
          else if (searchResultCount != null && searchResultCount! > 0)
            FilledButton.icon(
              onPressed: onPlay,
              icon: const Icon(Icons.play_arrow_rounded),
              label: const Text('播放结果'),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 18),
                shape: const StadiumBorder(),
              ),
            ),
        ],
      ),
    );
  }
}

class _SearchEmpty extends StatelessWidget {
  const _SearchEmpty();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 40, 18, 160),
      child: Column(
        children: [
          Icon(
            Icons.search_off_rounded,
            size: 48,
            color: colorScheme.onSurfaceVariant.withValues(alpha: .5),
          ),
          const SizedBox(height: 12),
          Text(
            '没有找到匹配的歌曲',
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
              color: colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _LoadMoreFooter extends StatelessWidget {
  const _LoadMoreFooter({
    required this.hasMore,
    required this.isLoading,
    required this.errorMessage,
    required this.onRetry,
  });

  final bool hasMore;
  final bool isLoading;
  final String? errorMessage;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    if (errorMessage != null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(18, 10, 18, 118),
        child: Center(
          child: TextButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('加载失败，点击重试'),
          ),
        ),
      );
    }

    if (isLoading) {
      return const Padding(
        padding: EdgeInsets.fromLTRB(18, 14, 18, 118),
        child: Center(
          child: SizedBox.square(
            dimension: 22,
            child: CircularProgressIndicator(strokeWidth: 2.4),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 118),
      child: Center(
        child: Text(
          hasMore ? '继续下滑加载更多' : '已加载全部',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

class _SongRow extends StatelessWidget {
  const _SongRow({
    super.key,
    required this.song,
    required this.index,
    required this.player,
    required this.canDelete,
    required this.selecting,
    required this.selected,
    required this.onTap,
    required this.onAddToPlaylist,
    required this.onDelete,
    required this.onViewArtist,
  });

  final Song song;
  final int index;
  final PlayerController player;
  final bool canDelete;
  final bool selecting;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onAddToPlaylist;
  final VoidCallback onDelete;
  final VoidCallback onViewArtist;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    // 歌曲行响应 player 重建，高频更新会触发 Windows AXTree 竞态崩溃
    return ExcludeSemantics(
      child: AnimatedBuilder(
        animation: player,
        builder: (context, _) {
          final active = !selecting && player.currentSong?.hash == song.hash;
          final activeColor = colorScheme.primary;
          return InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: onTap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
              decoration: BoxDecoration(
                color: selecting
                    ? (selected
                          ? activeColor.withValues(alpha: .08)
                          : Colors.transparent)
                    : active
                    ? activeColor.withValues(alpha: .09)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(
                children: [
                  if (selecting) ...[
                    Checkbox(
                      value: selected,
                      onChanged: (_) => onTap(),
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      visualDensity: VisualDensity.compact,
                    ),
                    const SizedBox(width: 4),
                  ],
                  SizedBox.square(
                    dimension: 50,
                    child: Stack(
                      children: [
                        Artwork(url: song.coverUrl, size: 50, borderRadius: 9),
                        if (!selecting)
                          Positioned(
                            left: 4,
                            top: 4,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: .42),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 5,
                                  vertical: 1,
                                ),
                                child: Text(
                                  '$index',
                                  style: Theme.of(context).textTheme.labelSmall
                                      ?.copyWith(
                                        color: Colors.white.withValues(
                                          alpha: .78,
                                        ),
                                        fontWeight: FontWeight.w800,
                                        height: 1.1,
                                      ),
                                ),
                              ),
                            ),
                          ),
                        if (active)
                          Positioned(
                            right: 4,
                            bottom: 4,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: colorScheme.surface.withValues(
                                  alpha: .9,
                                ),
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
                                fontWeight: FontWeight.w800,
                              ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          song.artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(
                                color: active
                                    ? activeColor.withValues(alpha: .72)
                                    : colorScheme.onSurfaceVariant,
                              ),
                        ),
                      ],
                    ),
                  ),
                  if (!selecting) ...[
                    const SizedBox(width: 10),
                    Text(
                      formatDuration(song.duration),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: active
                            ? activeColor.withValues(alpha: .72)
                            : colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    IconButton(
                      tooltip: '更多',
                      onPressed: () {
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
                              onTap: onAddToPlaylist,
                            ),
                            SongSheetAction(
                              icon: Icons.person_rounded,
                              title: '查看歌手',
                              onTap: onViewArtist,
                            ),
                            if (canDelete)
                              SongSheetAction(
                                icon: Icons.delete_outline_rounded,
                                title: '从歌单删除',
                                danger: true,
                                onTap: onDelete,
                              ),
                            if (player.downloadController != null)
                              SongSheetAction(
                                icon:
                                    player.downloadController!.isDownloaded(
                                      song,
                                    )
                                    ? Icons.download_done_rounded
                                    : Icons.download_rounded,
                                title:
                                    player.downloadController!.isDownloaded(
                                      song,
                                    )
                                    ? '已下载'
                                    : '下载',
                                onTap: () => player.downloadController!
                                    .download(song, player.audioQuality),
                              ),
                          ],
                        );
                      },
                      icon: const Icon(Icons.more_horiz_rounded),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _DetailError extends StatelessWidget {
  const _DetailError({
    required this.title,
    required this.message,
    required this.onRetry,
  });

  final String title;
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.error_outline_rounded, size: 42),
          const SizedBox(height: 12),
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(
            message,
            textAlign: TextAlign.center,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('重试'),
          ),
        ],
      ),
    );
  }
}

enum _SongSortMode { defaultOrder, byTitle, byArtist, byAlbum }

class _SortOptionTile extends StatelessWidget {
  const _SortOptionTile({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: selected ? colorScheme.primary : null,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ),
            if (selected)
              Icon(Icons.check_rounded, size: 20, color: colorScheme.primary),
          ],
        ),
      ),
    );
  }
}

String _detailMeta(PlaylistSummary info) {
  if (info.isCollectedAlbum) {
    if (info.songCount != null) {
      return '${info.songCount} 首歌';
    }
    return '新专辑';
  }
  final parts = <String>[];
  if (info.songCount != null) {
    parts.add('${info.songCount} 首歌');
  }
  if (info.playCount != null) {
    parts.add(_playCount(info.playCount));
  }
  return parts.isEmpty ? '来自 ${AppConfig.appName}' : parts.join(' · ');
}

String _playCount(int? value) {
  if (value == null) {
    return '精选歌单';
  }
  if (value >= 10000) {
    return '${(value / 10000).toStringAsFixed(1)} 万次播放';
  }
  return '$value 次播放';
}
