// 私人 FM API 层（MusicApi.personalFm）：
// - 走 fork Rust 引擎的 `/personal/fm` 路由，参数名必须是 snake_case
//   （song_pool_id / is_overplay / remain_song_cnt），而不是上游 .NET 后端的
//   camelCase；
// - 无反馈参数 = 纯刷新；带反馈参数 = 上报当前播放行为换取下一批；
// - 响应解析 PersonalFmResponse.song_list，按 hash/id 去重且单批最多 5 首。
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/core/api_client.dart';
import 'package:shiyin_music/core/api_client_interface.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/services/music_api.dart';

class _FakePersonalFmClient implements ApiClientInterface {
  _FakePersonalFmClient(this.response);

  final dynamic response;

  String? lastPath;
  Map<String, Object?>? lastQuery;

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
    if (path != '/personal/fm') {
      throw ArgumentError('Unexpected path: $path');
    }
    lastPath = path;
    lastQuery = Map<String, Object?>.of(query);
    return response;
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

Map<String, dynamic> _item(int index, {String? hash, String? title}) => {
  'songname': title ?? '推荐歌曲$index',
  'author_name': '歌手$index',
  'hash': hash ?? 'HASH_$index',
  'time_length': 200 + index,
  'album_id': 'ALB_$index',
  'songid': 1000 + index,
  'mixsongid': '2000$index',
  'trans_param': {'union_cover': 'http://img.kugou.com/{size}/$index.jpg'},
};

void main() {
  group('MusicApi.personalFm', () {
    test('纯刷新：只传 mode/song_pool_id，解析 song_list', () async {
      final client = _FakePersonalFmClient({
        'song_list': [_item(1), _item(2)],
        'mode': 'normal',
        'status': 1,
        'error_code': 0,
      });
      final api = MusicApi(client);

      final songs = await api.personalFm();

      expect(client.lastPath, '/personal/fm');
      expect(client.lastQuery, {
        'mode': 'normal',
        'song_pool_id': 0,
        'action': 'play',
      });
      expect(songs.map((song) => song.hash), ['HASH_1', 'HASH_2']);
      expect(songs.first.title, '推荐歌曲1');
      expect(songs.first.duration, const Duration(seconds: 201));
    });

    test('带播放反馈：上报 snake_case 行为参数', () async {
      final client = _FakePersonalFmClient({
        'song_list': [_item(3)],
      });
      final api = MusicApi(client);

      final songs = await api.personalFm(
        hash: 'HASH_CURRENT',
        songId: '555',
        playtime: 42,
        isOverplay: true,
      );

      expect(client.lastQuery, {
        'mode': 'normal',
        'song_pool_id': 0,
        'action': 'play',
        'hash': 'HASH_CURRENT',
        'songid': '555',
        'playtime': 42,
        'is_overplay': true,
        'remain_song_cnt': 0,
      });
      expect(songs.single.hash, 'HASH_3');
    });

    test('失败信封（status/error_code 非成功）抛 ApiException 而不是伪装成空推荐', () async {
      final client = _FakePersonalFmClient({
        'status': 0,
        'error_code': 20028,
        'error': '本次请求需要验证',
      });
      final api = MusicApi(client);

      await expectLater(() => api.personalFm(), throwsA(isA<ApiException>()));
    });

    test('按 hash 去重且单批最多 5 首', () async {
      final client = _FakePersonalFmClient({
        'song_list': [
          _item(1),
          _item(2, hash: 'HASH_1'), // 与第一首同 hash：应被去重
          _item(3),
          _item(4),
          _item(5),
          _item(6),
          _item(7),
        ],
      });
      final api = MusicApi(client);

      final songs = await api.personalFm();

      expect(songs.length, 5);
      expect(songs.map((song) => song.hash).toSet().length, 5);
      expect(songs.map((song) => song.hash), [
        'HASH_1',
        'HASH_3',
        'HASH_4',
        'HASH_5',
        'HASH_6',
      ]);
    });

    test('空响应返回空列表（不抛错）', () async {
      final client = _FakePersonalFmClient({'song_list': []});
      final api = MusicApi(client);

      expect(await api.personalFm(), isEmpty);
    });
  });

  group('MusicApi.songUrl hashOnly', () {
    test('hashOnly 时不带专辑/音频 id', () async {
      var captured = <String, Object?>{};
      final client = _RecordingSongUrlClient((query) => captured = query);
      final api = MusicApi(client);

      await api.songUrl(
        const Song(
          id: 'sid',
          title: 't',
          artist: 'a',
          hash: 'HASH_X',
          albumId: 'ALB_X',
          albumAudioId: 'AUDIO_X',
        ),
        hashOnly: true,
      );

      expect(captured['hash'], 'HASH_X');
      expect(captured.containsKey('album_id'), isFalse);
      expect(captured.containsKey('album_audio_id'), isFalse);
    });

    test('默认仍带专辑/音频 id', () async {
      var captured = <String, Object?>{};
      final client = _RecordingSongUrlClient((query) => captured = query);
      final api = MusicApi(client);

      await api.songUrl(
        const Song(
          id: 'sid',
          title: 't',
          artist: 'a',
          hash: 'HASH_X',
          albumId: 'ALB_X',
          albumAudioId: 'AUDIO_X',
        ),
      );

      expect(captured['album_id'], 'ALB_X');
      expect(captured['album_audio_id'], 'AUDIO_X');
    });
  });
}

class _RecordingSongUrlClient implements ApiClientInterface {
  _RecordingSongUrlClient(this.onQuery);

  final void Function(Map<String, Object?>) onQuery;

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
    if (path != '/song/url') {
      throw ArgumentError('Unexpected path: $path');
    }
    onQuery(query);
    return {'url': 'https://example.com/a.mp3', 'hash': 'HASH_X'};
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
