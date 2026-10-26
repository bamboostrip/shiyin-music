part of 'music_api.dart';

/// 歌曲播放地址 / 高潮片段 / 云盘 / 评论。
mixin _MusicApiSong on _MusicApiBase {
  Future<MusicCommentResponse> musicComments(
    String mixsongid, {
    int page = 1,
    int pageSize = 30,
  }) async {
    final json = asMap(
      await _client.get('/comment/music', {
        'mixsongid': mixsongid,
        'page': page,
        'pagesize': pageSize,
      }),
    );
    final response = MusicCommentResponse.fromJson(json);
    // Rust 层失败时仍回传原始信封（status/error_code/msg）。list 为空
    // 且 status 非成功时必须抛错，否则 UI 会误显示「还没有人评论」。
    final status = response.status ?? asInt(json['status']);
    final errorCode = response.errorCode ?? asInt(json['error_code']);
    final ok =
        (status == null || status == 1 || status == 200) &&
        (errorCode == null || errorCode == 0);
    if (!ok && (response.list == null || response.list!.isEmpty)) {
      throw ApiException(
        response.message ?? response.msg ?? '评论服务暂不可用',
        statusCode: errorCode,
      );
    }
    return response;
  }

  /// 获取歌曲高潮片段时间信息，无高潮时返回 null。
  Future<SongClimax?> songClimax(String hash) async {
    final raw = await _client.get('/song/climax', {'hash': hash});
    final json = asMap(raw);
    final items = raw is List ? raw : asList(json['data']);
    for (final item in items.whereType<Map<String, dynamic>>()) {
      final climax = SongClimax.fromJson(item);
      if (climax.isValid) return climax;
    }
    return null;
  }

  /// [hashOnly] 为 true 时只按 hash 取地址（不传专辑/音频 id）。
  ///
  /// 私人 FM（酷狗官方猜你喜欢）下发的歌曲没有稳定可用的专辑/音频 id，
  /// 带上它们反而会让服务端查不到音源；该场景下的播放链路统一走 hash。
  Future<PlayUrl> songUrl(
    Song song, {
    AudioQuality quality = AudioQuality.standard,
    bool hashOnly = false,
  }) async {
    final json = asMap(
      await _client.get('/song/url', {
        'hash': song.hash,
        'quality': quality.apiValue,
        if (!hashOnly) ...{
          'album_id': song.albumId,
          'album_audio_id': song.albumAudioId,
        },
        'free_part': false,
      }),
    );
    final playUrl = PlayUrl.fromJson(json);
    if (playUrl.url.isEmpty && playUrl.requiresVip) {
      throw const VipRequiredException();
    }
    return playUrl;
  }

  /// 获取云盘歌曲列表（分页）。
  Future<CloudDriveResult> cloudDrive({int page = 1, int pageSize = 30}) async {
    final json = asMap(
      await _client.get('/user/cloud', {'page': page, 'pagesize': pageSize}),
    );
    final info = CloudDriveInfo.fromJson(json);
    final songs = asList(json['list'])
        .whereType<Map<String, dynamic>>()
        .map(CloudDriveSongMeta.fromJson)
        .where((item) => item.song.hash.isNotEmpty)
        .map((item) => item.song)
        .toList();
    return CloudDriveResult(info: info, songs: songs);
  }

  /// 获取云盘歌曲的播放地址。
  Future<PlayUrl> cloudSongUrl(Song song) async {
    final json = asMap(
      await _client.get('/user/cloud/url', {
        'hash': song.hash,
        'album_audio_id': song.albumAudioId,
        'audio_id': song.albumAudioId,
        'name': song.title,
      }),
    );
    final url = asString(json['url']) ?? '';
    final hash = asString(json['hash']) ?? song.hash;
    return PlayUrl(url: url, hash: hash);
  }
}
