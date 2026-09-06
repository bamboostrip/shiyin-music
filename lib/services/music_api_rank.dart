part of 'music_api.dart';

/// 推荐 / 新歌 / 排行榜 / 电台 FM。
mixin _MusicApiRank on _MusicApiBase {
  Future<DailyRecommend> dailyRecommend() async {
    final json = asMap(await _client.get('/recommend/songs'));
    return DailyRecommend.fromJson(json);
  }

  /// 新歌速递。
  Future<List<Song>> topSongs({int type = 21608, int page = 1}) async {
    final raw = await _client.get('/top/song', {'type': type, 'page': page});
    final json = asMap(raw);
    final items = raw is List
        ? raw
        : asList(json['data'] ?? json['song_list'] ?? _firstListValue(json));
    return items
        .whereType<Map<String, dynamic>>()
        .map(Song.fromTopSong)
        .where((song) => song.hash.isNotEmpty)
        .toList();
  }

  // -------------------------------------------------------------------------
  // 排行榜 (Rank)
  // -------------------------------------------------------------------------

  Future<List<RankCategory>> rankList({int withSong = 0}) async {
    final json = asMap(await _client.get('/rank/list', {'withsong': withSong}));
    final data = asMap(json['data']);
    final items = asList(
      data['info'] ?? json['info'] ?? json['list'] ?? json['ranks'],
    );
    return items
        .whereType<Map<String, dynamic>>()
        .map(RankCategory.fromJson)
        .where((c) => c.rankId > 0)
        .toList();
  }

  Future<RankSongPage> rankAudio({
    required int rankId,
    int rankCid = 0,
    int page = 1,
    int pageSize = 30,
  }) async {
    final raw = await _client.get('/rank/audio', {
      'rankid': rankId,
      'rank_cid': rankCid,
      'page': page,
      'pagesize': pageSize,
    });
    final List items;
    if (raw is List) {
      items = raw;
    } else {
      final json = asMap(raw);
      final nested = asMap(json['data']);
      items = asList(
        json['songlist'] ??
            json['info'] ??
            json['songs'] ??
            json['list'] ??
            json['items'] ??
            nested['songlist'] ??
            nested['info'] ??
            nested['songs'] ??
            nested['list'],
      );
    }
    final songs = items
        .whereType<Map<String, dynamic>>()
        .map(Song.fromRank)
        .where((s) => s.hash.isNotEmpty)
        .toList();
    final total = raw is List
        ? raw.length
        : asInt(asMap(raw)['total']) ?? songs.length;
    return RankSongPage(songs: songs, total: total);
  }

  /// 拉取榜单全部分页歌曲（排行榜详情页"播放全部"与后台补全播放队列用）。
  ///
  /// 与 [playlistSongs] 的 fetchAll 同构：循环翻页直到某页不足 [pageSize]
  /// （过滤后条数，与 RankDetailPage 的 _hasMore 判定一致）或达到 [maxPages]
  /// 防御上限（防止上游异常数据导致死循环）。
  Future<List<Song>> rankAudioAll({
    required int rankId,
    int rankCid = 0,
    int pageSize = 50,
    int maxPages = 30,
  }) async {
    final allSongs = <Song>[];
    for (var page = 1; page <= maxPages; page++) {
      final result = await rankAudio(
        rankId: rankId,
        rankCid: rankCid,
        page: page,
        pageSize: pageSize,
      );
      allSongs.addAll(result.songs);
      if (result.songs.length < pageSize) break;
    }
    return allSongs;
  }

  Future<List<Song>> newSongs({int rankId = 0, int page = 1}) async {
    final json = asMap(
      await _client.get('/top/song', {'rank_id': rankId, 'page': page}),
    );
    final data = asMap(json['data']);
    final items = asList(data['songs'] ?? data['info'] ?? data['list']);
    return items
        .whereType<Map<String, dynamic>>()
        .map(Song.fromRank)
        .where((s) => s.hash.isNotEmpty)
        .toList();
  }

  Future<List<FmStation>> fmRecommendedStations() async {
    final raw = await _client.get('/fm/recommend');
    final items = raw is List ? raw : asList(asMap(raw)['data']);
    return items
        .whereType<Map>()
        .map((item) => FmStation.fromJson(asMap(item)))
        .where((station) => station.id.isNotEmpty)
        .toList();
  }

  Future<List<FmClassGroup>> fmClassGroups() async {
    final raw = await _client.get('/fm/class');
    final json = asMap(raw);
    return asList(json['class_list'] ?? json['data'])
        .whereType<Map>()
        .map((item) => FmClassGroup.fromJson(asMap(item)))
        .where((group) => group.stations.isNotEmpty)
        .toList();
  }

  Future<List<Song>> fmSongs(
    FmStation station, {
    int offset = -1,
    int size = 20,
  }) async {
    final raw = await _client.get('/fm/songs', {
      'fmid': station.id,
      'type': station.type,
      'offset': offset,
      'size': size,
    });
    final items = raw is List ? raw : asList(asMap(raw)['data']);
    final pages = items
        .whereType<Map>()
        .map((item) => FmSongPage.fromJson(asMap(item)))
        .toList();
    if (pages.isEmpty) {
      return const [];
    }
    return pages.expand((page) => page.songs).toList();
  }

  Future<Map<String, FmImage>> fmImages(List<String> fmids) async {
    final ids = fmids.where((id) => id.isNotEmpty).toSet().join(',');
    if (ids.isEmpty) {
      return const {};
    }
    final raw = await _client.get('/fm/image', {'fmid': ids});
    final items = raw is List ? raw : asList(asMap(raw)['data']);
    return {
      for (final image
          in items
              .whereType<Map>()
              .map((item) => FmImage.fromJson(asMap(item)))
              .where((image) => image.fmid.isNotEmpty))
        image.fmid: image,
    };
  }
}
