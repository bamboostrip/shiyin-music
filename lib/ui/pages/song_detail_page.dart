/// PC 歌曲详情页：对齐参考稿（截图 4）——头部封面 + 歌名，下方
/// `评论 / 详情` 双 tab。
///
/// - 评论 tab：复用 [CommentListView]，标题经总数刷新为 `评论655` 样式；
/// - 详情 tab：演唱者 / 作词 / 作曲 / 专辑 / 发行年份 / 语种 / 时长 +
///   专辑简介，无数据行直接隐藏（制作人/流派/唱片公司上游不下发，不展示）。
library;

import 'package:flutter/material.dart';

import '../../controllers/auth_controller.dart';
import '../../controllers/player_controller.dart';
import '../../models/music_models.dart';
import '../../services/music_api.dart';
import '../widgets/artwork.dart';
import '../player/player_comment_button.dart';
import 'artist_detail_page.dart';
import 'comment_list_view.dart';
import 'playlist_detail_page.dart';

/// 详情页初始 tab：歌名点进来落「详情」，评论按钮点进来落「评论」。
enum SongDetailTab { comments, detail }

class SongDetailPage extends StatefulWidget {
  const SongDetailPage({
    super.key,
    required this.api,
    required this.auth,
    required this.player,
    required this.song,
    this.initialTab = SongDetailTab.detail,
  });

  final MusicApi api;
  final AuthController auth;
  final PlayerController player;
  final Song song;
  final SongDetailTab initialTab;

  @override
  State<SongDetailPage> createState() => _SongDetailPageState();
}

class _SongDetailPageState extends State<SongDetailPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  ArtistAlbum? _album;
  LyricCredits _credits = const LyricCredits();
  int? _commentCount;

  Song get _song => widget.song;

  /// 评论 mixsongid（与评论按钮同口径）：拿不到时评论 tab 展示占位。
  String? get _mixsongid {
    if (_song.source != SongSource.kugou) return null;
    final id = _song.albumAudioId ?? _song.id;
    return id.isEmpty ? null : id;
  }

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: 2,
      vsync: this,
      initialIndex: widget.initialTab == SongDetailTab.comments ? 0 : 1,
    );
    // 标题计数不依赖评论 tab 是否构建过：会话内已有（底栏/别处拉过）
    // 就秒显 `评论NNN`，否则等 CommentListView 首屏回报。
    final mixsongid = _mixsongid;
    if (mixsongid != null) _commentCount = cachedCommentCount(mixsongid);
    _loadDetail();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  /// 可复用的 player 内存歌词：与正在播放同一首且内存已有歌词时直接取
  /// 词曲，零请求（本地 .lrc/内嵌歌词只在 loadLyrics 走，直调 api 反而
  /// 拿不到）。单测 fake 未实现 currentSong/lyrics 时会抛，此时按
  /// “无缓存”降级走网络（与 _safeApi 同类守卫）。
  List<LyricLine> _reusablePlayerLyrics() {
    try {
      if (widget.player.currentSong?.hash == _song.hash) {
        return widget.player.lyrics;
      }
    } catch (_) {
      // fake 未实现 → 无缓存可用，走网络。
    }
    return const [];
  }

  /// 专辑详情与歌词并行拉取；失败不抛，缺行隐藏。
  Future<void> _loadDetail() async {
    final albumFuture = _song.albumId?.isNotEmpty == true
        ? widget.api.albumDetail(_song.albumId!).catchError((_) => null)
        : Future<ArtistAlbum?>.value();
    final playerLyrics = _reusablePlayerLyrics();
    final lyricsFuture = playerLyrics.isNotEmpty
        ? Future<LyricCredits>.value(extractLyricCredits(playerLyrics))
        : widget.api
              .lyrics(_song)
              .then<LyricCredits>(extractLyricCredits)
              .catchError((_) => const LyricCredits());
    final results = await Future.wait([albumFuture, lyricsFuture]);
    if (!mounted) return;
    setState(() {
      _album = results[0] as ArtistAlbum?;
      _credits = results[1] as LyricCredits;
    });
  }

  String? get _publishYear {
    final raw = _album?.publishDate?.trim();
    if (raw == null || raw.isEmpty) return null;
    return RegExp(r'^(\d{4})').firstMatch(raw)?.group(1);
  }

  ArtistRef? get _jumpArtist {
    for (final artist in _song.artists) {
      if (artist.name.isNotEmpty && artist.id.isNotEmpty) return artist;
    }
    return null;
  }

  void _openArtist(ArtistRef artist) {
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

  void _openAlbum() {
    final albumId = _song.albumId;
    if (albumId == null || albumId.isEmpty) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlaylistDetailPage(
          api: widget.api,
          auth: widget.auth,
          player: widget.player,
          playlist: PlaylistSummary(
            id: albumId,
            title: _album?.name ?? _song.albumName ?? '未知专辑',
            subtitle: _song.artist,
            coverUrl: _album?.coverUrl ?? _song.coverUrl,
            sourceListId: albumId,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final mixsongid = _mixsongid;
    return Scaffold(
      // 不透明底：全屏路由直推时也不透出下层（播放页深色背景）；
      // 内容区内与 shell 底色一致，观感不变。
      backgroundColor: colorScheme.surface,
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 左侧窄轨：返回键落在内容区左侧空档（宽窗时即左侧大片留白处），
          // 窄窗也只是固定占 64px，绝不与封面重叠。
          if (Navigator.of(context).canPop())
            const SizedBox(
              width: 64,
              child: Padding(
                padding: EdgeInsets.only(top: 16),
                child: Align(
                  alignment: Alignment.topCenter,
                  child: _BackButton(),
                ),
              ),
            ),
          Expanded(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 860),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(28, 16, 28, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 头部：封面 + 歌名 + 歌手/专辑一行。
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Artwork(
                            url: _song.coverUrl,
                            size: 120,
                            borderRadius: 12,
                          ),
                          const SizedBox(width: 20),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  _song.title,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context)
                                      .textTheme
                                      .headlineSmall
                                      ?.copyWith(fontWeight: FontWeight.w800),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  _headerSubtitle(),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.bodyMedium
                                      ?.copyWith(
                                        color: colorScheme.onSurfaceVariant,
                                      ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                const SizedBox(height: 20),
                // 双 tab：评论（带数）/ 详情。
                TabBar(
                  controller: _tabController,
                  isScrollable: true,
                  tabAlignment: TabAlignment.start,
                  dividerColor: Colors.transparent,
                  indicatorSize: TabBarIndicatorSize.label,
                  indicatorWeight: 3,
                  labelStyle: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                  ),
                  unselectedLabelStyle: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w400,
                  ),
                  tabs: [
                    Tab(
                      text: _commentCount == null
                          ? '评论'
                          : '评论$_commentCount',
                    ),
                    const Tab(text: '详情'),
                  ],
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: TabBarView(
                    controller: _tabController,
                    children: [
                      if (mixsongid == null)
                        const _NoCommentPlaceholder()
                      else
                        CommentListView(
                          api: widget.api,
                          mixsongid: mixsongid,
                          onCountChanged: (count) {
                            if (!mounted || count == _commentCount) return;
                            // 回写会话缓存：同一首歌在底栏/详情页之间共享，
                            // 下次进详情页标题秒显，不必等列表构建。
                            if (count != null) {
                              cacheCommentCount(mixsongid, count);
                            }
                            setState(() => _commentCount = count);
                          },
                        ),
                      _DetailTab(
                        song: _song,
                        album: _album,
                        credits: _credits,
                        publishYear: _publishYear,
                        jumpArtist: _jumpArtist,
                        onOpenArtist: _openArtist,
                        onOpenAlbum: _openAlbum,
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
      ],
    )
  );
}

  String _headerSubtitle() {
    final parts = <String>[];
    if (_song.artist.isNotEmpty) parts.add('歌手：${_song.artist}');
    final albumName = _album?.name ?? _song.albumName;
    if (albumName?.isNotEmpty == true) parts.add('专辑：$albumName');
    return parts.join('　　');
  }
}

/// 左侧窄轨返回键：裸箭头，对齐歌单页 SliverAppBar 的 leading 样式。
class _BackButton extends StatelessWidget {
  const _BackButton();

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: '返回',
      onPressed: () => Navigator.of(context).pop(),
      icon: const Icon(Icons.arrow_back_rounded),
    );
  }
}

class _NoCommentPlaceholder extends StatelessWidget {
  const _NoCommentPlaceholder();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        '暂无评论',
        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// 详情 tab：`标签：值` 两列行，无数据行隐藏（制作人/流派/唱片公司
/// 上游不下发，不展示）。
class _DetailTab extends StatelessWidget {
  const _DetailTab({
    required this.song,
    required this.album,
    required this.credits,
    required this.publishYear,
    required this.jumpArtist,
    required this.onOpenArtist,
    required this.onOpenAlbum,
  });

  final Song song;
  final ArtistAlbum? album;
  final LyricCredits credits;
  final String? publishYear;
  final ArtistRef? jumpArtist;
  final ValueChanged<ArtistRef> onOpenArtist;
  final VoidCallback onOpenAlbum;

  @override
  Widget build(BuildContext context) {
    final rows = <_DetailRowData>[
      _DetailRowData(
        label: '演唱者',
        value: song.artist,
        onTap: jumpArtist == null ? null : () => onOpenArtist(jumpArtist!),
      ),
      if (credits.lyricist != null)
        _DetailRowData(label: '作词', value: credits.lyricist!),
      if (credits.composer != null)
        _DetailRowData(label: '作曲', value: credits.composer!),
      if ((album?.name ?? song.albumName)?.isNotEmpty == true)
        _DetailRowData(
          label: '专辑',
          value: album?.name ?? song.albumName!,
          onTap: song.albumId?.isNotEmpty == true ? onOpenAlbum : null,
        ),
      if (publishYear != null) _DetailRowData(label: '发行年份', value: publishYear!),
      if (album?.language?.isNotEmpty == true)
        _DetailRowData(label: '歌曲语种', value: album!.language!),
      _DetailRowData(label: '时长', value: formatDuration(song.duration)),
    ];
    final intro = album?.intro?.trim();

    return ListView(
      padding: const EdgeInsets.only(top: 8, bottom: 24),
      children: [
        for (final row in rows) _DetailRow(data: row),
        if (intro != null && intro.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(
            '专辑简介',
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(
            intro,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              height: 1.7,
            ),
          ),
        ],
      ],
    );
  }
}

class _DetailRowData {
  const _DetailRowData({required this.label, required this.value, this.onTap});

  final String label;
  final String value;
  final VoidCallback? onTap;
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.data});

  final _DetailRowData data;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final content = Padding(
      padding: const EdgeInsets.symmetric(vertical: 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 88,
            child: Text(
              data.label,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(
              data.value,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
    if (data.onTap == null) return content;
    return InkWell(
      onTap: data.onTap,
      borderRadius: BorderRadius.circular(8),
      child: content,
    );
  }
}
