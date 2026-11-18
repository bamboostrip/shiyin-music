// 4.6 回归：Song 模型的 albumAudioId 直接作为 /song/url 的 album_audio_id
// 参数下发（music_api_song.dart songUrl）。album_audio_id 优先的模型改动
// 不得破坏「首页推荐/每日推荐取播放地址」这条链路。
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/core/api_client.dart';
import 'package:shiyin_music/core/api_client_interface.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/services/music_api.dart';

/// 记录请求 query 的假客户端：只服务 /song/url。
class _RecordingApiClient implements ApiClientInterface {
  _RecordingApiClient({this.responder});

  /// 非空时用它的返回值模拟任意响应（业务错误信封 / null / 空地址等）。
  final dynamic Function()? responder;

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
    final custom = responder;
    if (custom != null) return custom();
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

Song _song() => const Song(
  id: '1',
  title: '晴天',
  artist: '周杰伦',
  hash: 'HASH_URL_1',
);

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
        'album_audio_id': 9009,
        'album_id': 'ALB_1',
      });

      final playUrl = await api.songUrl(song);

      expect(playUrl.url, 'https://example.com/audio.mp3');
      expect(client.lastSongUrlQuery?['hash'], 'HASH_001');
      expect(client.lastSongUrlQuery?['album_id'], 'ALB_1');
      expect(client.lastSongUrlQuery?['album_audio_id'], '9009');
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

  test('业务错误信封按可重试失败抛出，不能当成空地址', () async {
    final api = MusicApi(
      _RecordingApiClient(
        responder: () => <String, dynamic>{
          'status': 0,
          'error_code': 20010,
          'msg': '系统繁忙，请稍后再试',
        },
      ),
    );

    await expectLater(api.songUrl(_song()), throwsA(isA<ApiException>()));
  });

  test('空响应按可重试失败抛出', () async {
    final api = MusicApi(_RecordingApiClient(responder: () => null));

    await expectLater(api.songUrl(_song()), throwsA(isA<ApiException>()));
  });

  test('服务端明确返回空地址时仍交给播放器判无音源', () async {
    final api = MusicApi(
      _RecordingApiClient(responder: () => <String, dynamic>{
        'url': <String>[],
      }),
    );

    final playUrl = await api.songUrl(_song());

    expect(playUrl.url, isEmpty);
    expect(playUrl.requiresVip, isFalse);
  });

  test('VIP 权限仍抛 VipRequiredException（不被当业务错误）', () async {
    final api = MusicApi(
      _RecordingApiClient(responder: () => <String, dynamic>{
        'url': <String>[],
        'priv_status': 1,
      }),
    );

    await expectLater(
      api.songUrl(_song()),
      throwsA(isA<VipRequiredException>()),
    );
  });
}
