part of 'music_api.dart';

/// 歌单域：我的歌单 / 推荐歌单 / 相似歌单 / 歌单详情与曲目管理 / 外部歌单解析。
mixin _MusicApiPlaylist on _MusicApiBase {
  /// 云歌单「下架曲名称」短缓存：开页/上滑/全量补全可能在同一歌单内多次
  /// 触发补全，避免每页都重复请求 cloudlist。
  final Map<String, ({DateTime at, Map<String, Song> songs})>
  _shieldedMetaCache = {};

  Future<List<PlaylistSummary>> userPlaylists({
    int page = 1,
    int pageSize = 30,
  }) async {
    final json = asMap(
      await _client.get('/user/playlist', {'page': page, 'pagesize': pageSize}),
    );
    final currentUserId = asString(json['userid']);
    final rawItems = asList(json['info']).whereType<Map<String, dynamic>>();
    final playlists = rawItems
        .map(
          (item) =>
              PlaylistSummary.fromUser(item, currentUserId: currentUserId),
        )
        .where((item) => item.id.isNotEmpty)
        .toList();
    return _orderUserPlaylistsForDisplay(playlists);
  }

  Future<List<PlaylistSummary>> recommendedPlaylists({
    int categoryId = 0,
    int page = 1,
  }) async {
    final json = asMap(
      await _client.get('/top/playlist', {
        'category_id': categoryId,
        'page': page,
      }),
    );
    return asList(json['special_list'])
        .whereType<Map<String, dynamic>>()
        .map(PlaylistSummary.fromRecommend)
        .where((item) => item.id.isNotEmpty)
        .toList();
  }

  /// 获取相似歌单。
  Future<List<PlaylistSummary>> similarPlaylists(String ids) async {
    final raw = await _client.get('/playlist/similar', {'ids': ids});
    final json = asMap(raw);
    final groups = (raw is List ? raw : asList(json['data']))
        .whereType<Map<String, dynamic>>()
        .toList();
    final items = groups.isEmpty
        ? const <Map<String, dynamic>>[]
        : asList(
            groups.first['collection_list'],
          ).whereType<Map<String, dynamic>>();
    return items
        .map(PlaylistSummary.fromSimilar)
        .where((playlist) => playlist.id.isNotEmpty)
        .toList();
  }

  Future<PlaylistSummary> playlistInfo(String id) async {
    final json = asMap(await _client.get('/playlist/detail', {'ids': id}));
    return PlaylistSummary.fromDetail(json);
  }

  Future<List<Song>> playlistSongs(
    String id, {
    int page = 1,
    int pageSize = 80,
    bool fetchAll = false,
  }) async {
    if (!fetchAll) {
      final songPage = await playlistSongPage(
        id,
        page: page,
        pageSize: pageSize,
      );
      return songPage.songs;
    }
    return (await playlistSongsPageAll(id)).songs;
  }

  /// 全量拉取歌单曲目，保留原始顺序与原始条数（[SongPage.rawItemCount]）。
  ///
  /// 上游 `/playlist/track/all` 会下发已下架/无版权（无 hash）的曲目，
  /// [playlistSongPage] 的 [SongPage.songs] 会把它们过滤掉；[SongPage.allSongs]
  /// 保留原始顺序供展示层置灰显示。原始条数累计后与过滤后条数之差
  /// 即「不可播放」的数量，供歌单详情页对齐元信息 count 与可播放条数
  /// （issue #6：收藏 530 首只显示 514 首）。
  ///
  /// [includeShieldedMeta] 为 true 时，额外用自家云歌单接口按 fileid 补全
  /// 下架曲目的原始文件名/歌手（上游歌单接口对它们只返回 `{fileid, shield}`）。
  Future<SongPage> playlistSongsPageAll(
    String id, {
    bool includeShieldedMeta = false,
    String? listId,
  }) async {
    var allSongs = <Song>[];
    final playableSongs = <Song>[];
    var rawItemCount = 0;
    var currentPage = 1;
    const perPage = 200;
    // 与 rankAudioAll 同构：某页 rawItemCount 不足一页即终止；并设防御页数
    // 上限，防止上游异常数据（永远满页）导致死循环。不提前按"过滤后为空"
    // break：满页全是无 hash 下架歌曲时 rawItemCount 仍满页，提前 break 会
    // 截断列表；空页 rawItemCount 为 0 同样能正确终止。
    const maxPages = 30;
    while (currentPage <= maxPages) {
      final songPage = await playlistSongPage(
        id,
        page: currentPage,
        pageSize: perPage,
      );
      allSongs.addAll(songPage.orderedSongs);
      playableSongs.addAll(songPage.songs);
      rawItemCount += songPage.rawItemCount;
      if (songPage.rawItemCount < perPage) break;
      currentPage++;
    }
    if (includeShieldedMeta && allSongs.any((song) => song.hash.isEmpty)) {
      allSongs = await _fillShieldedMeta(allSongs, id, listId: listId);
    }
    return SongPage(
      songs: playableSongs,
      rawItemCount: rawItemCount,
      allSongs: allSongs,
    );
  }

  Future<SongPage> playlistSongPage(
    String id, {
    int page = 1,
    int pageSize = 80,
    bool includeShieldedMeta = false,
    String? listId,
  }) async {
    final json = asMap(
      await _client.get('/playlist/track/all', {
        'id': id,
        'page': page,
        'pagesize': pageSize,
      }),
    );
    final items = asList(json['songs']);
    // 无 hash（下架/无版权等）不进可播放列表，但仍保留在 allSongs 里：
    // 设置开启时展示层可以按原始顺序置灰显示，rawItemCount 仍用接口条数
    // 判断分页。
    var ordered = items
        .whereType<Map<String, dynamic>>()
        .map(Song.fromPlaylist)
        .toList();
    if (includeShieldedMeta && ordered.any((song) => song.hash.isEmpty)) {
      ordered = await _fillShieldedMeta(ordered, id, listId: listId);
    }
    final songs = ordered.where((song) => song.hash.isNotEmpty).toList();
    return SongPage(
      songs: songs,
      rawItemCount: items.length,
      allSongs: ordered,
    );
  }

  /// 自家云歌单里已下架/无版权曲目的原始文件名（fileid → Song，hash 恒空）。
  ///
  /// `/playlist/track/all` 对这类条目只给 `{fileid, shield:1}`，而 cloudlist
  /// 接口（`/v4/get_list_all_file`）仍保留用户收藏时的文件名、时长与
  /// mixsongid。仅对自己的歌单有效；收藏来的他人歌单会返回空，调用方静默
  /// 保留占位即可。任何异常都返回空表，不能让「显示已下架歌曲」拖垮歌单加载。
  Future<Map<String, Song>> playlistUnavailableMeta(
    String playlistId, {
    String? listId,
  }) async {
    final numericListId = (listId != null && listId.trim().isNotEmpty)
        ? listId.trim()
        : _parseListId(playlistId);
    if (numericListId == null || numericListId.isEmpty) {
      return const <String, Song>{};
    }
    final cached = _shieldedMetaCache[numericListId];
    if (cached != null &&
        DateTime.now().difference(cached.at) < const Duration(minutes: 5)) {
      return cached.songs;
    }
    final meta = <String, Song>{};
    const pageSize = 200;
    // 防御页数上限：异常 count 不应导致无限翻页。
    const maxPages = 20;
    for (var page = 1; page <= maxPages; page++) {
      final json = asMap(
        await _client.get('/playlist/track/all/new', {
          'listid': numericListId,
          'page': page,
          'pagesize': pageSize,
        }),
      );
      final info = asList(
        json['info'],
      ).whereType<Map<String, dynamic>>().toList();
      for (final item in info) {
        final song = _songFromCloudList(item);
        if (song.id.isNotEmpty) meta[song.id] = song;
      }
      final count = asInt(json['count']) ?? 0;
      if (info.length < pageSize || meta.length >= count) break;
    }
    _shieldedMetaCache[numericListId] = (at: DateTime.now(), songs: meta);
    return meta;
  }

  /// 从 `collection_3_<userid>_<listid>_0` 解析出云歌单需要的数字 listid。
  String? _parseListId(String playlistId) {
    final match = RegExp(
      r'^collection_3_\d+_(\d+)_0$',
    ).firstMatch(playlistId.trim());
    return match?.group(1);
  }

  Future<List<Song>> _fillShieldedMeta(
    List<Song> songs,
    String playlistId, {
    String? listId,
  }) async {
    if (!songs.any((song) => song.hash.isEmpty)) return songs;
    try {
      final meta = await playlistUnavailableMeta(
        playlistId,
        listId: listId,
      );
      if (meta.isEmpty) return songs;
      return [
        for (final song in songs)
          song.hash.isEmpty ? (meta[song.id] ?? song) : song,
      ];
    } catch (_) {
      // 名称补全只是锦上添花：接口失败时保留「未知歌曲」占位，不影响加载/播放。
      return songs;
    }
  }

  /// 把 cloudlist 条目转成仅用于展示的 [Song]。
  ///
  /// cloudlist 的 `name` 是用户收藏时的文件名（形如 `歌手 - 歌名.mp3`），
  /// `singerinfo` 对已下架曲目通常为空名，需要从文件名前缀兜底解析歌手。
  /// 注意：`hash` 是用户本地上传文件哈希，不是可播放源，必须保持为空，
  /// 否则下架曲会被误当成可播放曲目加入队列。
  Song _songFromCloudList(Map<String, dynamic> json) {
    var name = (asString(json['name']) ?? '').trim();
    name = name.replaceFirst(
      RegExp(r'\.(mp3|flac|m4a|aac|wav|ogg|ape|wma)$', caseSensitive: false),
      '',
    );
    var prefixArtist = '';
    final separator = name.indexOf(' - ');
    if (separator > 0) {
      prefixArtist = name.substring(0, separator).trim();
      name = name.substring(separator + 3).trim();
    }
    final singerNames = asList(json['singerinfo'])
        .whereType<Map<String, dynamic>>()
        .map((item) => asString(item['name']) ?? '')
        .where((item) => item.isNotEmpty)
        .toList();
    final artist = singerNames.isNotEmpty
        ? singerNames.join(' / ')
        : prefixArtist;
    final album = asMap(json['albuminfo']);
    final albumName = asString(album['name']);
    return Song(
      id: asString(json['fileid']) ?? '',
      title: name.isEmpty ? '未知歌曲' : name,
      rawTitle: name.isEmpty ? null : name,
      artist: artist.isEmpty ? '未知艺人' : artist,
      hash: '',
      albumId: asString(json['album_id']),
      albumAudioId: asString(json['mixsongid']),
      albumName: albumName != null && albumName.isNotEmpty ? albumName : null,
      coverUrl: normalizeImageUrl(asString(json['cover'])),
      duration: durationFromMilliseconds(json['timelen']),
      artists: artist.isEmpty
          ? const []
          : [ArtistRef(id: '', name: artist)],
    );
  }

  Future<PlaylistDetail> playlistDetail(String id) async {
    final results = await Future.wait([
      playlistInfo(id),
      playlistSongs(id, pageSize: 50),
    ]);
    return PlaylistDetail(
      info: results[0] as PlaylistSummary,
      songs: results[1] as List<Song>,
    );
  }

  /// 解析网易云 / QQ 音乐歌单分享链接，返回歌单名、曲目列表（QQ 含歌手/时长）。
  ///
  /// QQ 音乐公开歌单接口无需登录、且不是酷狗接口，按任务书约定允许 Dart 直连
  /// （见 docs/upstream-sync/2026-10-26-next-batch-tasks.md 0.4 第 2 条例外）；
  /// 酷狗相关请求仍必须走 Rust engine。其余平台（如网易云）继续走旧的
  /// Rust `/playlist/external/parse`，保持双路径兼容。
  Future<ExternalPlaylistParseResult> parseExternalPlaylist(
    String sourceText,
  ) async {
    final qqUri = QqPlaylistService.shareUri(sourceText);
    if (qqUri != null) {
      final client = http.Client();
      try {
        return await QqPlaylistService(client).load(qqUri);
      } finally {
        client.close();
      }
    }
    final json = asMap(
      await _client.post(
        '/playlist/external/parse',
        body: {'sourceText': sourceText},
      ),
    );
    return ExternalPlaylistParseResult.fromJson(json);
  }

  Future<void> createPlaylist(String name, {bool private = false}) async {
    await _client.post(
      '/playlist/create',
      query: {'name': name, 'type': private ? 1 : 0},
    );
  }

  Future<void> collectPlaylist({
    required String name,
    required String globalCollectionId,
  }) async {
    await _client.post(
      '/playlist/add',
      query: {'name': name, 'list_create_gid': globalCollectionId},
    );
  }

  Future<void> deletePlaylist(String listId) async {
    await _client.post('/playlist/del', query: {'listid': listId});
  }

  Future<Map<String, dynamic>?> addToPlaylist(String listId, Song song) {
    return addSongsToPlaylist(listId, [song]);
  }

  Future<Map<String, dynamic>?> addSongsToPlaylist(
    String listId,
    List<Song> songs,
  ) async {
    if (songs.isEmpty) return null;
    final result = await _client.post(
      '/playlist/tracks/add',
      body: {'listId': listId, 'songs': songs.map(_songAddPayload).toList()},
    );
    final map = result is Map<String, dynamic> ? result : null;
    _ensurePlaylistOpSuccess(map, '添加');
    return map;
  }

  Future<Map<String, dynamic>?> removeFromPlaylist(String listId, Song song) {
    return removeSongsFromPlaylist(listId, [song]);
  }

  Future<Map<String, dynamic>?> removeSongsFromPlaylist(
    String listId,
    List<Song> songs, {
    List<int>? fileIds,
  }) async {
    final ids =
        fileIds ??
        songs
            .map((song) => int.tryParse(song.id) ?? 0)
            .where((id) => id != 0)
            .toList();
    if (ids.isEmpty) return null;
    final result = await _client.post(
      '/playlist/tracks/del',
      query: {'listid': listId, 'fileids': ids.join(',')},
    );
    final map = result is Map<String, dynamic> ? result : null;
    // Rust 层业务失败不抛错：这里必须校验 status/error_code，
    // 否则调用方（toggleLike / 歌单删除）会误判为成功，
    // 本地乐观状态在下次同步时被服务端真值打回。
    _ensurePlaylistOpSuccess(map, '删除');
    return map;
  }

  /// 歌单写操作统一校验：成功 status 为 1/200 且 error_code 为 0/缺省。
  /// 失败时抛错（含服务端 message），调用方回滚乐观状态并提示。
  void _ensurePlaylistOpSuccess(Map<String, dynamic>? resp, String action) {
    if (resp == null) return;
    final status = resp['status'];
    final errorCode = resp['error_code'] ?? resp['errcode'];
    final okStatus = status == null || status == 1 || status == 200;
    final okCode = errorCode == null || errorCode == 0;
    if (okStatus && okCode) return;
    final msg = resp['error'] ?? resp['err'] ?? resp['msg'] ?? resp['message'];
    final detail = msg is String && msg.trim().isNotEmpty
        ? '：$msg'
        : errorCode != null
        ? '（错误码 $errorCode）'
        : '';
    throw ApiException('$action失败$detail');
  }

  Map<String, Object?> _songAddPayload(Song song) {
    return {
      'name': song.title,
      'hash': song.hash,
      'albumId': song.albumId,
      'mixSongId': song.albumAudioId ?? song.id,
    };
  }
}

List<PlaylistSummary> _orderUserPlaylistsForDisplay(
  List<PlaylistSummary> playlists,
) {
  if (playlists.length <= 2) {
    return playlists;
  }
  return [...playlists.take(2), ...playlists.skip(2).toList().reversed];
}
