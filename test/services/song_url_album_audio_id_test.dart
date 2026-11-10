import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/core/api_client_interface.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/services/music_api.dart';

class _FakeApiClient implements ApiClientInterface {
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
    lastQuery = query;
    return <String, dynamic>{
      'url': ['https://example.com/x.mp3'],
      'hash': query['hash'],
      'priv_status': 0,
      'timelength': 100,
    };
  }

  @override
  Future<dynamic> getRaw(Uri uri) async => throw UnimplementedError();

  @override
  Future<dynamic> post(
    String path, {
    Map<String, Object?> query = const {},
    Map<String, Object?>? body,
  }) async =>
      throw UnimplementedError();

  @override
  void close() {}
}

void main() {
  group('Song.fromAlbum 的 albumAudioId', () {
    Map<String, dynamic> albumSongJson({
      Object? baseAudioId,
      String hash = '4E3B766A8A6BB7B87BF5D8D845820776',
    }) {
      return {
        'album_info': {'album_name': '太阳之子'},
        'audio_info': {'hash': hash, 'duration': 297000},
        'authors': [
          {'author_id': 3520, 'author_name': '周杰伦'},
        ],
        'base': {
          'album_audio_id': ?baseAudioId,
          'album_id': 179652761,
          'audio_name': '太阳之子',
          'author_name': '周杰伦',
        },
      };
    }

    test('优先取 base.album_audio_id（数字），不再用 hash 冒充', () {
      final song = Song.fromAlbum(albumSongJson(baseAudioId: 855700699));
      expect(song.albumAudioId, '855700699');
      expect(song.hash, '4E3B766A8A6BB7B87BF5D8D845820776');
      expect(song.albumId, '179652761');
    });

    test('响应没有数字 ID 时保持 null，而不是塞 hash', () {
      final song = Song.fromAlbum(albumSongJson());
      expect(song.albumAudioId, isNull);
      expect(song.hash, isNotEmpty);
    });
  });

  group('MusicApi.songUrl 的 album_audio_id 过滤', () {
    test('数字 album_audio_id 正常下发', () async {
      final client = _FakeApiClient();
      final api = MusicApi(client);
      final song = Song(
        id: '1',
        title: '歌',
        artist: '手',
        hash: 'HASH',
        albumId: '179652761',
        albumAudioId: '855700699',
      );

      await api.songUrl(song);

      expect(client.lastQuery?['hash'], 'HASH');
      expect(client.lastQuery?['album_id'], '179652761');
      expect(client.lastQuery?['album_audio_id'], '855700699');
    });

    test('hash 形态的 album_audio_id 被过滤掉', () async {
      final client = _FakeApiClient();
      final api = MusicApi(client);
      final song = Song(
        id: '1',
        title: '歌',
        artist: '手',
        hash: 'HASH',
        albumId: '179652761',
        albumAudioId: '4E3B766A8A6BB7B87BF5D8D845820776',
      );

      await api.songUrl(song);

      expect(client.lastQuery?.containsKey('album_audio_id'), isFalse);
      expect(client.lastQuery?['album_id'], '179652761');
    });

    test('album 信息缺失时不下发空串（交给引擎默认 0）', () async {
      final client = _FakeApiClient();
      final api = MusicApi(client);
      const song = Song(id: '1', title: '歌', artist: '手', hash: 'HASH');

      await api.songUrl(song);

      expect(client.lastQuery?.containsKey('album_id'), isFalse);
      expect(client.lastQuery?.containsKey('album_audio_id'), isFalse);
    });
  });
}
