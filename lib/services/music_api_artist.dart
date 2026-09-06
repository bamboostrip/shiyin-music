part of 'music_api.dart';

/// 歌手与专辑。
mixin _MusicApiArtist on _MusicApiBase {
  Future<ArtistDetail> artistDetail(String id) async {
    final json = asMap(await _client.get('/artist/detail', {'id': id}));
    return ArtistDetail.fromJson(json, id: id);
  }

  /// 获取歌手专辑列表。
  Future<List<ArtistAlbum>> artistAlbums(
    String id, {
    int page = 1,
    int pageSize = 20,
  }) async {
    final raw = await _client.get('/artist/albums', {
      'id': id,
      'page': page,
      'pagesize': pageSize,
      'sort': 'new',
    });
    final json = asMap(raw);
    final items = raw is List
        ? raw
        : asList(
            json['data'] ??
                json['albums'] ??
                json['list'] ??
                _firstListValue(json),
          );
    return items
        .whereType<Map<String, dynamic>>()
        .map(ArtistAlbum.fromJson)
        .where((album) => album.id.isNotEmpty)
        .toList();
  }

  Future<List<Song>> artistAudios(
    String id, {
    int page = 1,
    int pageSize = 30,
    String sort = 'hot',
  }) async {
    final raw = await _client.get('/artist/audios', {
      'id': id,
      'page': page,
      'pagesize': pageSize,
      'sort': sort,
    });

    final json = asMap(raw);
    final items = raw is List
        ? raw
        : asList(
            json['data'] ??
                json['songs'] ??
                json['song'] ??
                json['list'] ??
                json['info'] ??
                _firstListValue(json),
          );
    return items
        .whereType<Map<String, dynamic>>()
        .map((item) => Song.fromArtistAudio(item, artistId: id))
        .where((song) => song.hash.isNotEmpty)
        .toList();
  }

  /// 拉取专辑全部歌曲。
  ///
  /// 上游 /v1/album_audio/lite 单页上限 50（超过返回 invalid param），
  /// 因此按页循环直至拿不满一页，保证全量加载完整。
  Future<List<Song>> albumSongs(
    String id, {
    int page = 1,
    int pageSize = 30,
  }) async {
    final limit = pageSize.clamp(1, 50);
    final songs = <Song>[];
    var currentPage = page;
    while (true) {
      final songPage = await albumSongPage(
        id,
        page: currentPage,
        pageSize: limit,
      );
      songs.addAll(songPage.songs);
      if (songPage.rawItemCount < limit) break;
      currentPage++;
    }
    return songs;
  }

  Future<SongPage> albumSongPage(
    String id, {
    int page = 1,
    int pageSize = 30,
  }) async {
    final raw = await _client.get('/album/songs', {
      'id': id,
      'page': page,
      'pagesize': pageSize,
    });
    final json = asMap(raw);
    final items = raw is List
        ? raw
        : asList(
            json['songs'] ??
                json['data'] ??
                json['info'] ??
                _firstListValue(json),
          );
    final songs = items
        .whereType<Map<String, dynamic>>()
        .map(Song.fromAlbum)
        .where((song) => song.hash.isNotEmpty)
        .toList();
    return SongPage(songs: songs, rawItemCount: items.length);
  }
}
