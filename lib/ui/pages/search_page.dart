import 'dart:async';

import 'package:flutter/material.dart';

import '../../controllers/auth_controller.dart';
import '../../controllers/player_controller.dart';
import '../../controllers/theme_controller.dart';
import '../../models/music_models.dart';
import '../../services/music_api.dart';
import '../../services/search_history_service.dart';
import '../widgets/artwork.dart';
import '../widgets/horizontal_wheel_scroll.dart';
import '../widgets/mini_player.dart';
import '../widgets/toast.dart';
import '../adaptive_layout.dart';
import '../keyboard_focus_guard.dart';
import 'artist_detail_page.dart';
import 'playlist_detail_page.dart';
import 'dart:math' as math;
import 'search_song_results.dart';

class SearchPage extends StatefulWidget {
  const SearchPage({
    super.key,
    required this.api,
    required this.auth,
    required this.player,
  });

  final MusicApi api;
  final AuthController auth;
  final PlayerController player;

  @override
  State<SearchPage> createState() => _SearchPageState();
}

/// 搜索平台。
enum _SearchPlatform { kugou, netease }

/// 酷狗搜索类型。
enum _SearchType { song, artist, album }

class _SearchPageState extends State<SearchPage> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  Timer? _debounce;

  List<SearchHotCategory> _hotCategories = const [];
  var _hotLoading = true;
  List<String> _suggestions = const [];
  List<Song> _results = const [];
  List<SearchArtistResult> _artistResults = const [];
  List<SearchAlbumResult> _albumResults = const [];
  bool _loading = false;
  bool _searched = false;
  // 输入框焦点态：外层白卡边框据此染 primary，内层强制无边框，
  // 避免主题 focusedBorder 蓝圈和外卡叠成双边框。
  bool _searchFocused = false;
  _SearchPlatform _platform = _SearchPlatform.kugou;
  _SearchType _searchType = _SearchType.song;

  // 搜索历史
  final _historyService = SearchHistoryService();
  List<String> _searchHistory = const [];

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_handleFocusChanged);
    _focusNode.requestFocus();
    _loadHotKeywords();
    _loadSearchHistory();
    _controller.addListener(_onTextChanged);
  }

  void _handleFocusChanged() {
    if (!mounted) return;
    final focused = _focusNode.hasFocus;
    if (focused != _searchFocused) {
      setState(() => _searchFocused = focused);
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _focusNode.removeListener(_handleFocusChanged);
    _controller.dispose();
    _focusNode.dispose();
    _results = const [];
    _artistResults = const [];
    _albumResults = const [];
    _suggestions = const [];
    _hotCategories = const [];
    _searchHistory = const [];
    super.dispose();
  }

  Future<void> _loadHotKeywords() async {
    try {
      final categories = await widget.api.searchHotKeywords();
      if (mounted) {
        setState(() {
          _hotCategories = categories;
          _hotLoading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _hotLoading = false);
      }
    }
  }

  /// 加载本地搜索历史。
  Future<void> _loadSearchHistory() async {
    final history = await _historyService.getHistory();
    if (mounted) setState(() => _searchHistory = history);
  }

  void _onTextChanged() {
    _debounce?.cancel();
    final text = _controller.text.trim();
    if (text.isEmpty) {
      setState(() {
        _suggestions = const [];
        _results = const [];
        _searched = false;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 300), () {
      _fetchSuggestions(text);
    });
  }

  Future<void> _fetchSuggestions(String keywords) async {
    try {
      final suggestions = await widget.api.searchSuggest(keywords);
      if (mounted && _controller.text.trim() == keywords) {
        setState(() => _suggestions = suggestions);
      }
    } catch (_) {}
  }

  Future<void> _search(String keywords) async {
    if (keywords.isEmpty) return;
    _debounce?.cancel();
    setState(() {
      _loading = true;
      _suggestions = const [];
      _searched = true;
    });
    try {
      if (_platform == _SearchPlatform.netease) {
        final songs = await widget.api.searchNetEaseSongs(keywords);
        if (mounted) setState(() => _results = songs);
      } else {
        switch (_searchType) {
          case _SearchType.song:
            final songs = await widget.api.searchSongs(keywords);
            if (mounted) setState(() => _results = songs);
          case _SearchType.artist:
            final artists = await widget.api.searchArtists(keywords);
            if (mounted) setState(() => _artistResults = artists);
          case _SearchType.album:
            final albums = await widget.api.searchAlbums(keywords);
            if (mounted) setState(() => _albumResults = albums);
        }
      }
      // 搜索成功后记录历史
      await _historyService.add(keywords);
      await _loadSearchHistory();
    } catch (error) {
      if (mounted) {
        setState(() {
          _results = const [];
          _artistResults = const [];
          _albumResults = const [];
        });
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _onSubmit() {
    final text = _controller.text.trim();
    if (text.isNotEmpty) {
      _focusNode.unfocus();
      _search(text);
    }
  }

  /// 键盘提交（Enter）入口：IME 组词期间忽略提交。
  ///
  /// 组词中的 Enter 是"选词"而非"确认"，照常提交会误发搜索
  /// （见 keyboard_focus_guard.dart 的 IME 守卫；纯防御，触屏无风险）。
  void _onSubmitFromKeyboard() {
    if (isImeComposingActive(_controller.value)) return;
    _onSubmit();
  }

  void _onKeywordTap(String keyword) {
    _controller.text = keyword;
    _controller.selection = TextSelection.fromPosition(
      TextPosition(offset: keyword.length),
    );
    _search(keyword);
  }

  void _switchPlatform(_SearchPlatform platform) {
    if (_platform == platform) return;
    setState(() => _platform = platform);
    // 如果已有搜索关键词，切换平台后自动重新搜索
    final text = _controller.text.trim();
    if (text.isNotEmpty && _searched) {
      _search(text);
    }
  }

  void _switchSearchType(_SearchType type) {
    if (_searchType == type) return;
    setState(() => _searchType = type);
    final text = _controller.text.trim();
    if (text.isNotEmpty && _searched) {
      _search(text);
    }
  }

  void _playSong(Song song) {
    widget.player.playSong(song, queue: _results);
  }

  void _openArtist(Song song) {
    if (song.source != SongSource.kugou) {
      Toast.info('其他平台歌曲暂不支持查看歌手');
      return;
    }
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

  Widget _buildCarSearchHeader(BuildContext context, ColorScheme colorScheme) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Row(
      children: [
        IconButton(
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.arrow_back_ios_new_rounded),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Container(
            height: 46,
            decoration: BoxDecoration(
              color: isDark
                  ? colorScheme.surfaceContainerHighest
                  : colorScheme.surfaceContainerHighest.withValues(alpha: .54),
              borderRadius: BorderRadius.circular(23),
              border: Border.all(
                color: _searchFocused
                    ? colorScheme.primary.withValues(alpha: .65)
                    : isDark
                        ? colorScheme.outlineVariant.withValues(alpha: .85)
                        : colorScheme.outlineVariant.withValues(alpha: .45),
                width: _searchFocused ? 1.3 : 1,
              ),
            ),
            child: TextField(
              controller: _controller,
              focusNode: _focusNode,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _onSubmitFromKeyboard(),
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: isDark
                        ? colorScheme.onSurface.withValues(alpha: .92)
                        : null,
                  ),
              decoration: InputDecoration(
                filled: false,
                prefixIcon: Icon(
                  Icons.search_rounded,
                  color: isDark
                      ? colorScheme.onSurface.withValues(alpha: .92)
                      : colorScheme.onSurfaceVariant,
                ),
                suffixIcon: _controller.text.isNotEmpty
                    ? IconButton(
                        icon: Icon(
                          Icons.close_rounded,
                          color: isDark
                              ? colorScheme.onSurface.withValues(alpha: .86)
                              : null,
                        ),
                        onPressed: () {
                          _controller.clear();
                          _focusNode.requestFocus();
                        },
                      )
                    : null,
                hintText: '搜索歌曲，歌手',
                hintStyle: TextStyle(
                  color: isDark
                      ? colorScheme.onSurface.withValues(alpha: .62)
                      : colorScheme.onSurfaceVariant,
                ),
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                disabledBorder: InputBorder.none,
                errorBorder: InputBorder.none,
                focusedErrorBorder: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(vertical: 11),
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        ElevatedButton(
          onPressed: _onSubmit,
          style: ElevatedButton.styleFrom(
            backgroundColor: colorScheme.primary,
            foregroundColor: colorScheme.onPrimary,
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(23),
            ),
          ),
          child: const Text(
            '搜索',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final isLandscape = size.width > size.height;
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // 车机式搜索栏仅在车机模式开启时使用，普通横屏用标准布局。
    final isCarMode = isLandscape && ThemeController.instance.carModeEnabled;

    if (isCarMode) {
      return Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
            child: Column(
              children: [
                _buildCarSearchHeader(context, colorScheme),
                const SizedBox(height: 16),
                Expanded(
                  child: AnimatedBuilder(
                    animation: widget.auth,
                    builder: (context, _) => _buildBody(context),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        toolbarHeight: 64,
        titleSpacing: 4,
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Container(
          height: 42,
          decoration: BoxDecoration(
            color: isDark ? Colors.white.withValues(alpha: .07) : Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: _searchFocused
                  ? colorScheme.primary.withValues(alpha: .65)
                  : isDark
                      ? Colors.white.withValues(alpha: .10)
                      : Colors.white.withValues(alpha: .92),
              width: _searchFocused ? 1.3 : 1.1,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: isDark ? .18 : .06),
                blurRadius: 10,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Row(
            children: [
              const SizedBox(width: 14),
              Expanded(
                child: TextField(
                  controller: _controller,
                  focusNode: _focusNode,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _onSubmitFromKeyboard(),
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        color: isDark ? colorScheme.onSurface.withValues(alpha: .92) : null,
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                      ),
                  decoration: InputDecoration(
                    isDense: true,
                    filled: false,
                    suffixIcon: _controller.text.isNotEmpty
                        ? IconButton(
                            icon: Icon(Icons.close_rounded,
                                size: 18,
                                color: isDark
                                    ? colorScheme.onSurface.withValues(alpha: .86)
                                    : colorScheme.onSurfaceVariant),
                            onPressed: () {
                              _controller.clear();
                              _focusNode.requestFocus();
                              setState(() {});
                            },
                          )
                        : null,
                    hintText: '搜索歌曲、歌手、专辑',
                    hintStyle: TextStyle(
                      color: isDark
                          ? colorScheme.onSurface.withValues(alpha: .62)
                          : colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w500,
                      fontSize: 14,
                    ),
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    disabledBorder: InputBorder.none,
                    errorBorder: InputBorder.none,
                    focusedErrorBorder: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                ),
              ),
              // 无文字时补右内边距：有清除按钮时按钮自带边距，无按钮时
              // TextField 会贴到容器右边缘、压住外圈边框。
              if (_controller.text.isEmpty) const SizedBox(width: 14),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(
              '取消',
              style: TextStyle(
                color: colorScheme.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: AdaptiveContentPadding(
        child: Stack(
          children: [
            Positioned.fill(
              child: AnimatedBuilder(
                animation: widget.auth,
                builder: (context, _) => _buildBody(context),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: MediaQuery.paddingOf(context).bottom + 10,
              child: MiniPlayer(player: widget.player, auth: widget.auth),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final text = _controller.text.trim();

    return Column(
      children: [
        // 平台切换栏（仅搜索状态下显示）
        if (text.isNotEmpty || _searched)
          _PlatformSelector(platform: _platform, onChanged: _switchPlatform),
        // 酷狗搜索类型切换
        if ((text.isNotEmpty || _searched) &&
            _platform == _SearchPlatform.kugou)
          _SearchTypeSelector(
            type: _searchType,
            onChanged: _switchSearchType,
          ),
        Expanded(child: _buildContent(context, text)),
      ],
    );
  }

  Widget _buildContent(BuildContext context, String text) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_searched && text.isNotEmpty) {
      // 网易云只搜歌曲
      if (_platform == _SearchPlatform.netease) {
        return _results.isEmpty
            ? _EmptyResults(keyword: text)
            : SearchSongResults(
                songs: _results,
                onPlay: _playSong,
                isLiked: (song) => widget.auth.isLiked(song),
                onLikeTap: (song) => widget.auth.toggleLike(song),
                auth: widget.auth,
                player: widget.player,
                onViewArtist: _openArtist,
              );
      }
      // 酷狗按类型显示
      switch (_searchType) {
        case _SearchType.song:
          return _results.isEmpty
              ? _EmptyResults(keyword: text)
              : SearchSongResults(
                  songs: _results,
                  onPlay: _playSong,
                  isLiked: (song) => widget.auth.isLiked(song),
                  onLikeTap: (song) => widget.auth.toggleLike(song),
                  auth: widget.auth,
                  player: widget.player,
                  onViewArtist: _openArtist,
                );
        case _SearchType.artist:
          return _artistResults.isEmpty
              ? _EmptyResults(keyword: text)
              : _ArtistResults(
                  artists: _artistResults,
                  api: widget.api,
                  auth: widget.auth,
                  player: widget.player,
                );
        case _SearchType.album:
          return _albumResults.isEmpty
              ? _EmptyResults(keyword: text)
              : _AlbumResults(
                  albums: _albumResults,
                  api: widget.api,
                  auth: widget.auth,
                  player: widget.player,
                );
      }
    }

    if (text.isEmpty) {
      if (_hotLoading) {
        return const _HotSearchSkeleton();
      }

      final size = MediaQuery.sizeOf(context);
      final isLandscape = size.width > size.height;
      // 三列热搜布局是车机专属，普通横屏走下面的标准布局。
      final isCarMode = isLandscape && ThemeController.instance.carModeEnabled;

      if (isCarMode) {
        return ListView(
          padding: const EdgeInsets.fromLTRB(0, 8, 0, 16),
          children: [
            if (_searchHistory.isNotEmpty) ...[
              Row(
                children: [
                  Text(
                    '搜索历史',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w900,
                      fontSize: 18,
                    ),
                  ),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: () async {
                      await _historyService.clear();
                      _loadSearchHistory();
                      if (mounted) {
                        Toast.show('已清空搜索历史', type: ToastType.info);
                      }
                    },
                    child: Icon(
                      Icons.delete_outline_rounded,
                      size: 20,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _searchHistory.map((keyword) {
                  return _HistoryChip(
                    keyword: keyword,
                    onTap: () => _onKeywordTap(keyword),
                    onDelete: () async {
                      await _historyService.remove(keyword);
                      _loadSearchHistory();
                    },
                  );
                }).toList(),
              ),
              const SizedBox(height: 24),
            ],
            if (_hotCategories.isNotEmpty) ...[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (
                    var i = 0;
                    i < math.min(3, _hotCategories.length);
                    i++
                  ) ...[
                    Expanded(
                      child: _CarHotSearchColumn(
                        category: _hotCategories[i],
                        onTap: _onKeywordTap,
                      ),
                    ),
                    if (i < math.min(3, _hotCategories.length) - 1)
                      const SizedBox(width: 24),
                  ],
                ],
              ),
            ],
          ],
        );
      }

      // 历史记录 + 热搜面板：统一为白卡圆角设计，与我的页面/首页一致
      final isDark = Theme.of(context).brightness == Brightness.dark;
      final colorScheme = Theme.of(context).colorScheme;
      return ListView(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 160),
        children: [
          if (_searchHistory.isNotEmpty) ...[
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: isDark ? Colors.white.withValues(alpha: .06) : Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: isDark ? Colors.white.withValues(alpha: .10) : Colors.white.withValues(alpha: .92),
                  width: 1.1,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: isDark ? .18 : .06),
                    blurRadius: 10,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                          color: colorScheme.primary.withValues(alpha: isDark ? .18 : .10),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Icon(Icons.history_rounded, size: 16, color: colorScheme.primary),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          '搜索历史',
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w900,
                                fontSize: 16,
                              ),
                        ),
                      ),
                      GestureDetector(
                        onTap: () async {
                          await _historyService.clear();
                          _loadSearchHistory();
                          if (mounted) {
                            Toast.show('已清空搜索历史', type: ToastType.info);
                          }
                        },
                        child: Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: isDark ? Colors.white.withValues(alpha: .08) : colorScheme.surfaceContainerHighest.withValues(alpha: .9),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(Icons.delete_outline_rounded, size: 16, color: colorScheme.onSurfaceVariant),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: _searchHistory.map((keyword) {
                      return _HistoryChip(
                        keyword: keyword,
                        onTap: () => _onKeywordTap(keyword),
                        onDelete: () async {
                          await _historyService.remove(keyword);
                          _loadSearchHistory();
                        },
                      );
                    }).toList(),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
          ],
          if (_hotCategories.isEmpty)
            const SizedBox.shrink()
          else
            Container(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
              decoration: BoxDecoration(
                color: isDark ? Colors.white.withValues(alpha: .06) : Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: isDark ? Colors.white.withValues(alpha: .10) : Colors.white.withValues(alpha: .92),
                  width: 1.1,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: isDark ? .18 : .06),
                    blurRadius: 10,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: _HotSearchPanel(
                categories: _hotCategories,
                onTap: _onKeywordTap,
              ),
            ),
        ],
      );
    }

    if (_suggestions.isNotEmpty) {
      return _SuggestionList(suggestions: _suggestions, onTap: _onKeywordTap);
    }

    return const SizedBox.shrink();
  }
}

/// 平台切换选择器。
class _PlatformSelector extends StatelessWidget {
  const _PlatformSelector({required this.platform, required this.onChanged});

  final _SearchPlatform platform;
  final ValueChanged<_SearchPlatform> onChanged;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 4),
      child: Row(
        children: [
          for (final p in _SearchPlatform.values) ...[
            GestureDetector(
              onTap: () => onChanged(p),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  color: platform == p
                      ? colorScheme.primary
                      : colorScheme.surfaceContainerHighest.withValues(
                          alpha: .5,
                        ),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  p == _SearchPlatform.kugou ? '酷狗' : '网易云',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: platform == p
                        ? colorScheme.onPrimary
                        : colorScheme.onSurfaceVariant,
                    fontWeight: platform == p
                        ? FontWeight.w800
                        : FontWeight.w600,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
          ],
        ],
      ),
    );
  }
}

class _HotSearchSkeleton extends StatelessWidget {
  const _HotSearchSkeleton();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 160),
      children: [
        _SkeletonBlock(height: 22, width: 80),
        const SizedBox(height: 14),
        SizedBox(
          height: 36,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: 6,
            separatorBuilder: (_, _) => const SizedBox(width: 10),
            itemBuilder: (_, _) =>
                const _SkeletonBlock(height: 32, width: 72, radius: 16),
          ),
        ),
        const SizedBox(height: 22),
        for (var i = 0; i < 10; i++) ...[
          Padding(
            padding: EdgeInsets.only(bottom: i < 9 ? 10 : 0),
            child: Row(
              children: [
                const _SkeletonBlock(height: 16, width: 22),
                const SizedBox(width: 14),
                const Expanded(child: _SkeletonBlock(height: 16)),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _SkeletonBlock extends StatefulWidget {
  const _SkeletonBlock({this.height = 16, this.width, this.radius = 4});

  final double height;
  final double? width;
  final double radius;

  @override
  State<_SkeletonBlock> createState() => _SkeletonBlockState();
}

class _SkeletonBlockState extends State<_SkeletonBlock>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
    _animation = Tween(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOutSine),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return AnimatedBuilder(
      animation: _animation,
      builder: (context, _) {
        final alpha = isDark
            ? .06 + _animation.value * .08
            : .08 + _animation.value * .10;
        return Container(
          height: widget.height,
          width: widget.width,
          decoration: BoxDecoration(
            color: Theme.of(
              context,
            ).colorScheme.onSurface.withValues(alpha: alpha),
            borderRadius: BorderRadius.circular(widget.radius),
          ),
        );
      },
    );
  }
}

class _HotSearchPanel extends StatefulWidget {
  const _HotSearchPanel({required this.categories, required this.onTap});

  final List<SearchHotCategory> categories;
  final ValueChanged<String> onTap;

  @override
  State<_HotSearchPanel> createState() => _HotSearchPanelState();
}

class _HotSearchPanelState extends State<_HotSearchPanel> {
  late final PageController _pageController = PageController();
  var _page = 0;

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  // tab 点击 / 左右箭头：翻到指定榜（300ms easeOutCubic）。
  // 横滑由 PageView 自己跟手 + 松手吸附，松手后 onPageChanged 回写 _page，
  // 切页动画由手势驱动，用户一定感知得到，不会再"一闪而过"。
  void _goToPage(int index, int total) {
    final next = index.clamp(0, total - 1);
    if (next == _page) return;
    _pageController.animateToPage(
      next,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final categories = widget.categories;
    if (categories.isEmpty) return const SizedBox.shrink();
    final page = _page.clamp(0, categories.length - 1);
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: colorScheme.primary.withValues(alpha: isDark ? .18 : .10),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(Icons.local_fire_department_rounded, size: 16, color: colorScheme.primary),
            ),
            const SizedBox(width: 10),
            Text(
              '热搜',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w900,
                    fontSize: 16,
                  ),
            ),
            const Spacer(),
            // 当前榜单计数 + 左右切换箭头：切换方式一目了然，
            // 与 tab 点击、横滑手势三路同走 _goToPage。
            Text(
              '${page + 1} / ${categories.length}',
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w700,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
            ),
            const SizedBox(width: 6),
            _HotPageArrow(
              icon: Icons.chevron_left_rounded,
              enabled: page > 0,
              onTap: () => _goToPage(page - 1, categories.length),
            ),
            const SizedBox(width: 4),
            _HotPageArrow(
              icon: Icons.chevron_right_rounded,
              enabled: page < categories.length - 1,
              onTap: () => _goToPage(page + 1, categories.length),
            ),
          ],
        ),
        const SizedBox(height: 12),
        // 分段胶囊 tab 条：与首页顶部 tab 同一语言，选中态为立体白卡。
        Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: isDark
                ? Colors.white.withValues(alpha: .06)
                : colorScheme.surfaceContainerHighest.withValues(alpha: .55),
            borderRadius: BorderRadius.circular(14),
          ),
          child: SizedBox(
            height: 34,
            child: HorizontalWheelScroll(
              builder: (context, controller) => ListView.separated(
                controller: controller,
                scrollDirection: Axis.horizontal,
                padding: EdgeInsets.zero,
                itemCount: categories.length,
                separatorBuilder: (_, _) => const SizedBox(width: 4),
                itemBuilder: (context, index) {
                  final active = index == page;
                  return _CategoryTab(
                    label: categories[index].name,
                    active: active,
                    onTap: () => _goToPage(index, categories.length),
                  );
                },
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        // 榜单区锁高 360（约八行半：露出半行暗示榜内可滚），tab 条常驻可见，
        // 切榜时用户始终看得到自己在哪个榜。
        // 之前随内容撑高：榜单一长 tab 就被顶出屏幕，横滑切榜只剩内容一闪，
        // 用户感知不到切换。现在用真 PageView：横滑跟手 + 松手吸附。
        SizedBox(
          height: 360,
          child: HorizontalWheelPageScroll(
            controller: _pageController,
            child: PageView.builder(
              controller: _pageController,
              onPageChanged: (i) => setState(() => _page = i),
              itemCount: categories.length,
              itemBuilder: (context, index) {
                return _CategoryKeywordList(
                  keywords: categories[index].keywords,
                  onTap: widget.onTap,
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

/// 热搜头部左右切榜小箭头：28 见方圆角，与标题行图标底同一语言。
class _HotPageArrow extends StatelessWidget {
  const _HotPageArrow({
    required this.icon,
    required this.enabled,
    required this.onTap,
  });

  final IconData icon;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(9),
      child: InkWell(
        borderRadius: BorderRadius.circular(9),
        onTap: enabled ? onTap : null,
        child: Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: enabled
                ? colorScheme.primary.withValues(alpha: isDark ? .18 : .10)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(9),
          ),
          child: Icon(
            icon,
            size: 18,
            color: enabled
                ? colorScheme.primary
                : colorScheme.onSurfaceVariant.withValues(alpha: .35),
          ),
        ),
      ),
    );
  }
}

class _CategoryTab extends StatelessWidget {
  const _CategoryTab({
    required this.label,
    required this.active,
    required this.onTap,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      decoration: BoxDecoration(
        color: active
            ? (isDark ? colorScheme.primary.withValues(alpha: .20) : Colors.white)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        border: active && !isDark
            ? Border.all(color: colorScheme.primary.withValues(alpha: .18), width: 1)
            : null,
        boxShadow: active && !isDark
            ? [BoxShadow(color: Colors.black.withValues(alpha: .06), blurRadius: 8, offset: const Offset(0, 2))]
            : null,
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          child: Text(
            label,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: active ? colorScheme.primary : colorScheme.onSurfaceVariant,
                  fontWeight: active ? FontWeight.w800 : FontWeight.w600,
                  fontSize: 13,
                ),
          ),
        ),
      ),
    );
  }
}

class _CategoryKeywordList extends StatelessWidget {
  const _CategoryKeywordList({required this.keywords, required this.onTap});

  final List<SearchHotKeyword> keywords;
  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    // 榜内可滚：父级锁高 360，超出的行在这里滚，tab 条不受影响。
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: keywords.length,
      itemBuilder: (context, index) {
        final item = keywords[index];
        final rank = index + 1;
        return InkWell(
          onTap: () => onTap(item.keyword),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    SizedBox(
                      width: 28,
                      child: Text(
                        '$rank',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontWeight: _rankWeight(rank),
                          color: _rankColor(rank, colorScheme),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        item.keyword,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (rank <= 3 && item.reason != null && item.reason!.isNotEmpty)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: _rankColor(
                            rank,
                            colorScheme,
                          ).withValues(alpha: .14),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          '热',
                          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: _rankColor(rank, colorScheme),
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            );
      },
    );
  }

  FontWeight _rankWeight(int rank) {
    return rank <= 3 ? FontWeight.w900 : FontWeight.w600;
  }

  Color _rankColor(int rank, ColorScheme colorScheme) {
    return switch (rank) {
      1 => const Color(0xFFFF2D55),
      2 => const Color(0xFFFF6B35),
      3 => const Color(0xFFFFB020),
      _ => colorScheme.onSurfaceVariant,
    };
  }
}

class _SuggestionList extends StatelessWidget {
  const _SuggestionList({required this.suggestions, required this.onTap});

  final List<String> suggestions;
  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardColor = isDark ? Colors.white.withValues(alpha: .06) : Colors.white;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isDark ? Colors.white.withValues(alpha: .10) : Colors.white.withValues(alpha: .92),
            width: 1.1,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? .18 : .06),
              blurRadius: 10,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Material(
          color: cardColor,
          borderRadius: BorderRadius.circular(16),
          clipBehavior: Clip.antiAlias,
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(vertical: 6),
            shrinkWrap: true,
            itemCount: suggestions.length,
            separatorBuilder: (_, _) => Divider(
              height: 1,
              indent: 52,
              color: colorScheme.outlineVariant.withValues(alpha: .35),
            ),
            itemBuilder: (context, index) {
              final keyword = suggestions[index];
              return ListTile(
                dense: true,
                leading: Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: colorScheme.primary.withValues(alpha: isDark ? .18 : .10),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(Icons.search_rounded, size: 16, color: colorScheme.primary),
                ),
                title: Text(
                  keyword,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600, fontSize: 14),
          ),
          onTap: () => onTap(keyword),
        );
      },
          ),
        ),
      ),
    );
  }
}

class _EmptyResults extends StatelessWidget {
  const _EmptyResults({required this.keyword});

  final String keyword;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 60, 28, 160),
      child: Column(
        children: [
          Icon(
            Icons.search_off_rounded,
            size: 48,
            color: colorScheme.primary.withValues(alpha: .64),
          ),
          const SizedBox(height: 14),
          Text(
            '没有找到「$keyword」相关歌曲',
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(
            '换个关键词试试',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// 搜索历史标签 Chip。
///
/// 左侧为关键词，右侧带一个删除小图标；整体可点击触发搜索。
class _HistoryChip extends StatelessWidget {
  const _HistoryChip({
    required this.keyword,
    required this.onTap,
    required this.onDelete,
  });

  final String keyword;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      decoration: BoxDecoration(
        color: isDark ? Colors.white.withValues(alpha: .08) : Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isDark ? Colors.white.withValues(alpha: .10) : colorScheme.outlineVariant.withValues(alpha: .45),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? .14 : .05),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.only(left: 12, top: 6, bottom: 6, right: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  keyword,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600, fontSize: 13),
                ),
                const SizedBox(width: 6),
                GestureDetector(
                  onTap: onDelete,
                  child: Container(
                    padding: const EdgeInsets.all(3),
                    decoration: BoxDecoration(
                      color: isDark ? Colors.white.withValues(alpha: .10) : colorScheme.surfaceContainerHighest.withValues(alpha: .9),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(Icons.close_rounded, size: 12, color: colorScheme.onSurfaceVariant),
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

class _CarHotSearchColumn extends StatelessWidget {
  const _CarHotSearchColumn({required this.category, required this.onTap});

  final SearchHotCategory category;
  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          category.name,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w900,
            color: colorScheme.onSurface,
          ),
        ),
        const SizedBox(height: 12),
        ListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: math.min(6, category.keywords.length),
          itemBuilder: (context, index) {
            final item = category.keywords[index];
            final rank = index + 1;
            return InkWell(
              onTap: () => onTap(item.keyword),
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                child: Row(
                  children: [
                    SizedBox(
                      width: 24,
                      child: Text(
                        '$rank',
                        style: TextStyle(
                          fontWeight: rank <= 3
                              ? FontWeight.bold
                              : FontWeight.normal,
                          color: rank <= 3
                              ? Colors.redAccent
                              : colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        item.keyword,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w500),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 搜索类型选择器
// ---------------------------------------------------------------------------

class _SearchTypeSelector extends StatelessWidget {
  const _SearchTypeSelector({required this.type, required this.onChanged});

  final _SearchType type;
  final ValueChanged<_SearchType> onChanged;

  static const _labels = {
    _SearchType.song: '歌曲',
    _SearchType.artist: '歌手',
    _SearchType.album: '专辑',
  };

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 4, 18, 4),
      child: Row(
        children: [
          for (final t in _SearchType.values) ...[
            GestureDetector(
              onTap: () => onChanged(t),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: type == t
                      ? colorScheme.primary.withValues(alpha: .12)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: type == t
                        ? colorScheme.primary.withValues(alpha: .4)
                        : colorScheme.outlineVariant.withValues(alpha: .5),
                  ),
                ),
                child: Text(
                  _labels[t]!,
                  style: TextStyle(
                    fontSize: 13,
                    color: type == t
                        ? colorScheme.primary
                        : colorScheme.onSurfaceVariant,
                    fontWeight:
                        type == t ? FontWeight.w800 : FontWeight.w500,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 歌手搜索结果
// ---------------------------------------------------------------------------

class _ArtistResults extends StatelessWidget {
  const _ArtistResults({
    required this.artists,
    required this.api,
    required this.auth,
    required this.player,
  });

  final List<SearchArtistResult> artists;
  final MusicApi api;
  final AuthController auth;
  final PlayerController player;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      itemCount: artists.length,
      itemBuilder: (context, index) {
        final artist = artists[index];
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => ArtistDetailPage(
                  api: api,
                  auth: auth,
                  artist: ArtistRef(id: artist.id, name: artist.name),
                  player: player,
                ),
              ),
            );
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                Artwork(
                  url: artist.avatarUrl,
                  size: 52,
                  borderRadius: 26,
                  icon: Icons.person_rounded,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        artist.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: colorScheme.onSurface,
                        ),
                      ),
                      if (artist.songCount > 0) ...[
                        const SizedBox(height: 2),
                        Text(
                          '${artist.songCount} 首歌曲',
                          style: TextStyle(
                            fontSize: 12,
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                Icon(
                  Icons.chevron_right_rounded,
                  color: colorScheme.onSurfaceVariant.withValues(alpha: .5),
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
// 专辑搜索结果
// ---------------------------------------------------------------------------

class _AlbumResults extends StatelessWidget {
  const _AlbumResults({
    required this.albums,
    required this.api,
    required this.auth,
    required this.player,
  });

  final List<SearchAlbumResult> albums;
  final MusicApi api;
  final AuthController auth;
  final PlayerController player;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      itemCount: albums.length,
      itemBuilder: (context, index) {
        final album = albums[index];
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            final playlist = PlaylistSummary(
              id: album.albumId,
              title: album.albumName,
              subtitle: album.artistName,
              coverUrl: album.coverUrl,
              // 标记专辑侧 ID，使 isCollectedAlbum/albumId 走专辑分支（/album/songs）。
              sourceListId: album.albumId,
            );
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => PlaylistDetailPage(
                  api: api,
                  auth: auth,
                  player: player,
                  playlist: playlist,
                ),
              ),
            );
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                Artwork(url: album.coverUrl, size: 52, borderRadius: 8),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        album.albumName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: colorScheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        [
                          if (album.artistName.isNotEmpty) album.artistName,
                          if (album.songCount > 0) '${album.songCount} 首',
                        ].join(' · '),
                        style: TextStyle(
                          fontSize: 12,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  Icons.chevron_right_rounded,
                  color: colorScheme.onSurfaceVariant.withValues(alpha: .5),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
