// 4.6 回归：Song 模型的 albumAudioId 直接作为 /song/url 的 album_audio_id
// 参数下发（music_api_song.dart songUrl）。album_audio_id 优先的模型改动
// 不得破坏「首页推荐/每日推荐取播放地址」这条链路。
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/core/api_client_interface.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/services/music_api.dart';

/// 记录请求 query 的假客户端：只服务 /song/url。
class _RecordingApiClient implements ApiClientInterface {
  Map<String, Object?>? lastSongUrlQuery;

  @override
  String? token;
  @override
  String? t1;
  @override
  String? sessionId;

  @override
  Future<dynamic> get(
    String path, [
    Map<String, Object?> query = const {},
  ]) async {
    expect(path, '/song/url');
    lastSongUrlQuery = query;
    return <String, dynamic>{
      'url': <String>['https://example.com/audio.mp3'],
      'hash': query['hash'],
    };
  }

  @override
  Future<dynamic> getRaw(Uri uri) async => throw UnimplementedError();

  @override
  Future<dynamic> post(
    String path, {
    Map<String, Object?> query = const {},
    Map<String, Object?>? body,
  }) async => throw UnimplementedError();

  @override
  void close() {}
}

void main() {
  test(
    'fromTopCard 的 album_audio_id 进入 /song/url 的 album_audio_id 参数',
    () async {
      final client = _RecordingApiClient();
      final api = MusicApi(client);
      final song = Song.fromTopCard({
        'songname': '晴天',
        'hash': 'HASH_001',
        'songid': 1001,
        'mixsongid': '2002',
        'album_audio_id': 'AAID_9',
        'album_id': 'ALB_1',
      });

      final playUrl = await api.songUrl(song);

      expect(playUrl.url, 'https://example.com/audio.mp3');
      expect(client.lastSongUrlQuery?['hash'], 'HASH_001');
      expect(client.lastSongUrlQuery?['album_id'], 'ALB_1');
      expect(client.lastSongUrlQuery?['album_audio_id'], 'AAID_9');
    },
  );

  test('fromDaily 缺 album_audio_id 时仍按 mixsongid 下发（不回归）', () async {
    final client = _RecordingApiClient();
    final api = MusicApi(client);
    final song = Song.fromDaily({
      'songname': '七里香',
      'hash': 'HASH_002',
      'songid': 1001,
      'mixsongid': '2002',
    });

    await api.songUrl(song);

    expect(client.lastSongUrlQuery?['album_audio_id'], '2002');
  });
}
