/// 歌曲信息弹层（移动端底部弹层）：对齐参考稿的歌曲详情展示。
///
/// 首屏全部用 [Song] 自带字段零请求渲染（歌名/歌手/专辑/时长）；
/// 发行年份与专辑简介走 `/album/detail`（[MusicApi.albumDetail]），
/// 作词/作曲从歌词正文提取（[extractLyricCredits]）——两路并行加载，
/// 无数据直接隐藏对应行，不抛错。
library;

import 'package:flutter/material.dart';

import '../../controllers/auth_controller.dart';
import '../../controllers/player_controller.dart';
import '../../models/music_models.dart';
import '../pages/artist_detail_page.dart';
import '../pages/playlist_detail_page.dart';

/// 打开歌曲信息底部弹层。
Future<void> showSongInfoSheet({
  required BuildContext context,
  required PlayerController player,
  required AuthController auth,
  required Song song,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    backgroundColor: Theme.of(context).colorScheme.surfaceContainer,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (sheetContext) =>
        _SongInfoSheet(player: player, auth: auth, song: song),
  );
}

class _SongInfoSheet extends StatefulWidget {
  const _SongInfoSheet({
    required this.player,
    required this.auth,
    required this.song,
  });

  final PlayerController player;
  final AuthController auth;
  final Song song;

  @override
  State<_SongInfoSheet> createState() => _SongInfoSheetState();
}

class _SongInfoSheetState extends State<_SongInfoSheet> {
  ArtistAlbum? _album;
  LyricCredits _credits = const LyricCredits();

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// 可复用的 player 内存歌词：与正在播放同一首且内存已有歌词时直接取
  /// 词曲，零请求（本地 .lrc/内嵌歌词只在 loadLyrics 走，直调 api 反而
  /// 拿不到；看的是别的歌时 hash 对不上，仍走网络）。
  /// 单测 fake 未实现 currentSong/lyrics 时会抛，此时按“无缓存”降级
  /// 走网络（与 _safeApi 同类守卫）。
  List<LyricLine> _reusablePlayerLyrics(Song song) {
    try {
      if (widget.player.currentSong?.hash == song.hash) {
        return widget.player.lyrics;
      }
    } catch (_) {
      // fake 未实现 → 无缓存可用，走网络。
    }
    return const [];
  }

  /// 专辑详情与歌词并行拉取；任何一路失败都不影响弹层展示，
  /// 对应行直接隐藏（无数据不抛错）。
  Future<void> _load() async {
    final song = widget.song;
    final albumFuture = song.albumId?.isNotEmpty == true
        ? widget.player.api.albumDetail(song.albumId!).catchError(
            (_) => null,
          )
        : Future<ArtistAlbum?>.value();
    final playerLyrics = _reusablePlayerLyrics(song);
    final lyricsFuture = playerLyrics.isNotEmpty
        ? Future<LyricCredits>.value(extractLyricCredits(playerLyrics))
        : widget.player.api
              .lyrics(song)
              .then<LyricCredits>(extractLyricCredits)
              .catchError((_) => const LyricCredits());
    final results = await Future.wait([albumFuture, lyricsFuture]);
    if (!mounted) return;
    setState(() {
      _album = results[0] as ArtistAlbum?;
      _credits = results[1] as LyricCredits;
    });
  }

  /// 发行年份：publish_date 取前 4 位年份（如 `1999-07-01` → `1999`）。
  String? get _publishYear {
    final raw = _album?.publishDate?.trim();
    if (raw == null || raw.isEmpty) return null;
    final match = RegExp(r'^(\d{4})').firstMatch(raw);
    return match?.group(1);
  }

  /// 跳歌手页的首选歌手（有 id 的第一个，`>` 据此显隐）。
  ArtistRef? get _jumpArtist {
    for (final artist in widget.song.artists) {
      if (artist.name.isNotEmpty && artist.id.isNotEmpty) return artist;
    }
    return null;
  }

  void _openArtist(ArtistRef artist) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ArtistDetailPage(
          api: widget.player.api,
          auth: widget.auth,
          artist: artist,
          player: widget.player,
        ),
      ),
    );
  }

  void _openAlbum() {
    final song = widget.song;
    final albumId = song.albumId;
    if (albumId == null || albumId.isEmpty) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlaylistDetailPage(
          api: widget.player.api,
          auth: widget.auth,
          player: widget.player,
          // 标记专辑侧 ID，使 isCollectedAlbum/albumId 走专辑分支（/album/songs）。
          playlist: PlaylistSummary(
            id: albumId,
            title: _album?.name ?? song.albumName ?? '未知专辑',
            subtitle: song.artist,
            coverUrl: _album?.coverUrl ?? song.coverUrl,
            sourceListId: albumId,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final song = widget.song;
    final artistNames = song.artists
        .map((a) => a.name)
        .where((name) => name.isNotEmpty)
        .join(' / ');
    final jumpArtist = _jumpArtist;
    final hasAlbum = song.albumId?.isNotEmpty == true;
    final publishYear = _publishYear;
    final intro = _album?.intro?.trim();

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 2, 16, 22),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 标题行（对齐参考稿首行 `歌曲：xxx`，紧凑档 16）。
              Text(
                '歌曲：${song.title}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                  fontSize: 16,
                  height: 1.3,
                ),
              ),
              const SizedBox(height: 4),
              _InfoRow(
                icon: const Icon(Icons.person_outline_rounded),
                label: '歌手',
                value: artistNames.isNotEmpty ? artistNames : song.artist,
                onTap: jumpArtist == null ? null : () => _openArtist(jumpArtist),
              ),
              if (_credits.lyricist != null)
                _InfoRow(
                  icon: const _HanIcon(char: '词'),
                  label: '作词',
                  value: _credits.lyricist!,
                ),
              if (_credits.composer != null)
                _InfoRow(
                  icon: const _HanIcon(char: '曲'),
                  label: '作曲',
                  value: _credits.composer!,
                ),
              if ((_album?.name ?? song.albumName)?.isNotEmpty == true)
                _InfoRow(
                  icon: const Icon(Icons.album_outlined),
                  label: '专辑',
                  value: _album?.name ?? song.albumName!,
                  onTap: hasAlbum ? _openAlbum : null,
                ),
              if (publishYear != null)
                _InfoRow(
                  icon: const Icon(Icons.calendar_month_outlined),
                  label: '发行年份',
                  value: publishYear,
                ),
              _InfoRow(
                icon: const Icon(Icons.schedule_rounded),
                label: '时长',
                value: formatDuration(song.duration),
              ),
              // 专辑简介（album_detail 顺带，有才展示）。
              if (intro != null && intro.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  '专辑简介',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    fontSize: 13.5,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  intro,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                    fontSize: 13,
                    height: 1.55,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 信息行：图标 + `标签：值`，可跳时右带 `>`（对齐参考稿）。
///
/// 无 `onTap` 时纯展示（作词/作曲/发行年份/时长），不画 `>`。
class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.icon,
    required this.label,
    required this.value,
    this.onTap,
  });

  final Widget icon;
  final String label;
  final String value;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 9),
      child: Row(
        children: [
          IconTheme(
            data: IconThemeData(color: colorScheme.onSurface, size: 21),
            child: icon,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              '$label：$value',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                fontSize: 14.5,
                fontWeight: FontWeight.w500,
                height: 1.25,
              ),
            ),
          ),
          if (onTap != null)
            Container(
              width: 26,
              height: 26,
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.6,
                ),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(
                Icons.chevron_right_rounded,
                size: 18,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
    if (onTap == null) return content;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: content,
    );
  }
}

/// 方框汉字图标（对齐参考稿的 `词` / `曲` 标识）。
class _HanIcon extends StatelessWidget {
  const _HanIcon({required this.char});

  final String char;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 21,
      height: 21,
      decoration: BoxDecoration(
        border: Border.all(
          color: Theme.of(context).colorScheme.onSurface,
          width: 1.5,
        ),
        borderRadius: BorderRadius.circular(6),
      ),
      alignment: Alignment.center,
      child: Text(
        char,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w800,
          height: 1.0,
          color: Theme.of(context).colorScheme.onSurface,
        ),
      ),
    );
  }
}
