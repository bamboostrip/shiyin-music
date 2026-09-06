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
    return MusicCommentResponse.fromJson(json);
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

  Future<PlayUrl> songUrl(
    Song song, {
    AudioQuality quality = AudioQuality.standard,
  }) async {
    final json = asMap(
      await _client.get('/song/url', {
        'hash': song.hash,
        'quality': quality.apiValue,
        'album_id': song.albumId,
        'album_audio_id': song.albumAudioId,
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
