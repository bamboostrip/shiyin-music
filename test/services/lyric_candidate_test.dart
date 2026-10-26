import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/core/api_client_interface.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/services/music_api.dart';

/// 移植自上游 kgka_Music_hl 3.2.0 `bf264d9` 的歌词候选兜底：
/// 1. 先按 `hash` + `album_audio_id` 精确定位；
/// 2. 无候选（非标/播客/电台/版权变更）时用 `artist + title` 的关键字兜底；
/// 3. 候选选择仍走既有的 `_findLyricCandidate` 递归兜底（下面用嵌套响应覆盖）。
void main() {
  group('MusicApi.lyrics 歌词候选获取', () {
    test('hash + album_audio_id 命中：只请求一次，不触发关键字兜底', () async {
      final client = _FakeLyricApiClient(
        searchResponses: const [_candidateByHash],
      );
      final api = MusicApi(client);

      final lines = await api.lyrics(_song());

      expect(lines.length, 2);
      expect(lines[0].text, 'Hello');
      expect(lines[1].text, 'World');
      expect(client.searchQueries, [
        {'hash': 'HASH_1', 'album_audio_id': 'AAID_1'},
      ]);
      expect(client.lyricQueries.single['id'], '123');
      expect(client.lyricQueries.single['accesskey'], 'key123');
      expect(client.lyricQueries.single['fmt'], 'krc');
    });

    test('hash 无候选时用 artist + title 的 keywords 兜底（嵌套候选递归查找）', () async {
      final client = _FakeLyricApiClient(
        searchResponses: const [{}, _nestedCandidate],
      );
      final api = MusicApi(client);

      final lines = await api.lyrics(_song());

      expect(lines.length, 2);
      expect(client.searchQueries.length, 2);
      expect(client.searchQueries[0], {
        'hash': 'HASH_1',
        'album_audio_id': 'AAID_1',
      });
      // Dart 侧与上游一致传复数 keywords；Rust 引擎 /search/lyric 做别名。
      expect(client.searchQueries[1], {'keywords': '测试歌手 测试歌'});
      expect(client.lyricQueries.single['id'], '9');
    });

    test('albumAudioId 缺省时不携带 album_audio_id 参数', () async {
      final client = _FakeLyricApiClient(
        searchResponses: const [_candidateByHash],
      );
      final api = MusicApi(client);

      await api.lyrics(_song(albumAudioId: null));

      expect(client.searchQueries.single, {'hash': 'HASH_1'});
    });

    test('hash 为空时直接走关键字兜底', () async {
      final client = _FakeLyricApiClient(
        searchResponses: const [_candidateByHash],
      );
      final api = MusicApi(client);

      final lines = await api.lyrics(_song(hash: ''));

      expect(lines.length, 2);
      expect(client.searchQueries.single, {'keywords': '测试歌手 测试歌'});
    });

    test('标题为未知歌曲时不发关键字兜底请求，返回空歌词', () async {
      final client = _FakeLyricApiClient(searchResponses: const [{}]);
      final api = MusicApi(client);

      final lines = await api.lyrics(_song(title: '未知歌曲'));

      expect(lines, isEmpty);
      expect(client.searchQueries.single, {
        'hash': 'HASH_1',
        'album_audio_id': 'AAID_1',
      });
      expect(client.lyricQueries, isEmpty);
    });

    test('关键字兜底请求抛异常时吞掉异常，返回空歌词而不是崩溃', () async {
      final client = _FakeLyricApiClient(
        searchResponses: [{}, Exception('network down')],
      );
      final api = MusicApi(client);

      final lines = await api.lyrics(_song());

      expect(lines, isEmpty);
      expect(client.searchQueries.length, 2);
    });
  });
}

Song _song({
  String? albumAudioId = 'AAID_1',
  String hash = 'HASH_1',
  String title = '测试歌',
}) {
  return Song(
    id: '1',
    title: title,
    artist: '测试歌手',
    hash: hash,
    albumAudioId: albumAudioId,
  );
}

const _candidateByHash = {
  'candidates': [
    {'id': 123, 'accesskey': 'key123'},
  ],
};

const _nestedCandidate = {
  'data': {
    'list': [
      {'id': 9, 'accesskey': 'key9'},
    ],
  },
};

const _krcContent = '''
[0,1000]<0,500,0>Hello
[1000,1000]<0,500,0>World
''';

class _FakeLyricApiClient implements ApiClientInterface {
  _FakeLyricApiClient({required this.searchResponses})
    : lyricResponse = const {'decodedContent': _krcContent};

  final List<Object?> searchResponses;
  final Object? lyricResponse;

  final List<Map<String, Object?>> searchQueries = [];
  final List<Map<String, Object?>> lyricQueries = [];

  int _searchIndex = 0;

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
    if (path == '/search/lyric') {
      searchQueries.add(Map<String, Object?>.from(query));
      final index = _searchIndex++;
      if (index >= searchResponses.length) {
        return const <String, dynamic>{};
      }
      final response = searchResponses[index];
      if (response is Exception) {
        throw response;
      }
      return response;
    }
    if (path == '/lyric') {
      lyricQueries.add(Map<String, Object?>.from(query));
      return lyricResponse;
    }
    throw ArgumentError('Unexpected path: $path');
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
