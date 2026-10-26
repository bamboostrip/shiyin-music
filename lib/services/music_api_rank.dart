part of 'music_api.dart';

/// 推荐 / 新歌 / 排行榜 / 电台 FM。
mixin _MusicApiRank on _MusicApiBase {
  Future<DailyRecommend> dailyRecommend() async {
    final json = asMap(await _client.get('/recommend/songs'));
    return DailyRecommend.fromJson(json);
  }

  /// 获取酷狗官方「猜你喜欢」（红心 Radio + 根据口味的私人 FM）。
  ///
  /// 不传播放反馈时是刷新推荐；传 [hash]/[songId]/[playtime] 时向服务端上报
  /// 当前歌曲的播放行为，服务端据此返回下一批推荐（见
  /// [PlayerController.startPersonalFm] 与私人 FM 会话的续批逻辑）。
  ///
  /// 注意参数名：本 fork 的 Rust 引擎 `/personal/fm` 路由按 snake_case 解析
  /// （song_pool_id / is_overplay / remain_song_cnt），与上游 .NET 后端的
  /// camelCase 查询参数不同。
  Future<List<Song>> personalFm({
    String? hash,
    String? songId,
    int? playtime,
    bool isOverplay = false,
  }) async {
    final hasPlaybackFeedback =
        hash != null || songId != null || playtime != null;
    final raw = await _client.get('/personal/fm', {
      'mode': 'normal',
      'song_pool_id': 0,
      if (hasPlaybackFeedback) ...{
        'hash': hash,
        'songid': songId,
        'playtime': playtime,
        'action': 'play',
        'is_overplay': isOverplay,
        'remain_song_cnt': 0,
      },
    });
    final json = asMap(raw);
    final songs = <Song>[];
    final identities = <String>{};
    for (final item in asList(json['song_list']).whereType<Map>()) {
      final song = Song.fromPersonalFm(asMap(item));
      final identity = song.hash.isNotEmpty ? song.hash : song.id;
      if (identity.isEmpty || !identities.add(identity)) {
        continue;
      }
      songs.add(song);
      if (songs.length == 5) {
        break;
      }
    }
    return songs;
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
    // total 只在服务端真的下发时才有值（未知保持 0）：它被 rankAudioAll /
    // RankDetailPage 用来做分页终止判定，若回退成本页过滤后条数，会把
    // 「本页恰好 N 条」误当「全榜单共 N 条」，第一页就提前终止翻页。
    // songlist 支持顶层 / data 嵌套两种形态，total 同样需要两处都看。
    final total = raw is List
        ? 0
        : asInt(asMap(raw)['total'] ?? asMap(asMap(raw)['data'])['total']) ?? 0;
    return RankSongPage(songs: songs, total: total);
  }

  /// 拉取榜单全部分页歌曲（排行榜详情页"播放全部"与后台补全播放队列用）。
  ///
  /// 终止判定优先用服务端 total：song 列表已按空 hash 过滤，页内被过滤掉
  /// 几条时按「过滤后条数 < pageSize」比较会把非末页误判为末页，导致
  /// "播放全部"队列缺歌。total 未知（<=0）时退回页大小启发式，并加空页
  /// 兜底与 [maxPages] 防御上限（防止上游异常数据导致死循环）。
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
      if (result.songs.isEmpty) break;
      if (result.total > 0) {
        if (allSongs.length >= result.total) break;
      } else if (result.songs.length < pageSize) {
        break;
      }
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
