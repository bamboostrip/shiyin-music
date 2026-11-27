import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/core/api_client_interface.dart';
import 'package:shiyin_music/services/music_api.dart';

class _FakeSearchApiClient implements ApiClientInterface {
  _FakeSearchApiClient(this.response);

  final dynamic response;

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
    if (path == '/search') {
      return response;
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
  }) async =>
      throw UnimplementedError();

  @override
  void close() {}
}

void main() {
  group('MusicApi.searchSongs（issue #40：免费歌曲不再被误当死链剔除）', () {
    test('cid=-1 且 FailProcess=0 的免费歌曲完整保留', () async {
      // issue #40 现场：酷狗 v3 complexsearch 返回的「江南雨未眠 (R&B慵懒女声版)」
      // 是免费内容（cid=-1 / FailProcess=0），但 FileHash 与专辑信息齐全、可播放。
      final fakeData = {
        'lists': [
          {
            'OriSongName': '江南雨未眠',
            'Suffix': '(R&B慵懒女声版)',
            'FileName': '姜明月 - 江南雨未眠 (R&B慵懒女声版)',
            'SingerName': '姜明月',
            'MixSongID': '835453666',
            'FileHash': 'EBC0B2EC3F8272899A9FE9B8ADA2A201',
            'FailProcess': 0,
            'trans_param': {'cid': -1},
          },
          {
            'OriSongName': '江南雨未眠',
            'FileName': '陈磐 - 江南雨未眠',
            'SingerName': '陈磐',
            'MixSongID': '820899003',
            'FileHash': 'F537461AA20BB87B449A2C0160F3CA93',
            'FailProcess': 4,
            'trans_param': {'cid': 551986490},
          },
        ],
      };

      final api = MusicApi(_FakeSearchApiClient(fakeData));
      final results = await api.searchSongs('江南雨未眠');

      expect(
        results.map((s) => s.title).toList(),
        ['江南雨未眠 (R&B慵懒女声版)', '江南雨未眠'],
      );
      expect(results.first.hash, 'EBC0B2EC3F8272899A9FE9B8ADA2A201');
    });

    test('cid / FailProcess 任意组合都不再影响保留', () async {
      final fakeData = [
        {
          'SongName': 'cid 为零',
          'FileHash': 'h0',
          'FailProcess': 0,
          'trans_param': {'cid': 0},
        },
        {
          'SongName': 'cid 为负',
          'FileHash': 'h1',
          'FailProcess': 0,
          'trans_param': {'cid': -1},
        },
        {
          'SongName': 'cid 为正',
          'FileHash': 'h2',
          'FailProcess': 0,
          'trans_param': {'cid': 100},
        },
        {'SongName': '无 trans_param', 'FileHash': 'h3'},
        {
          'SongName': 'FailProcess 非零',
          'FileHash': 'h4',
          'FailProcess': 4,
          'trans_param': {'cid': -1},
        },
      ];

      final api = MusicApi(_FakeSearchApiClient(fakeData));
      final results = await api.searchSongs('edge_cases');

      expect(results.map((s) => s.hash).toList(), ['h0', 'h1', 'h2', 'h3', 'h4']);
    });

    test('只有连 hash 都没有的条目仍被剔除', () async {
      final fakeData = [
        {
          'SongName': '无 hash',
          'FileHash': '',
          'FailProcess': 0,
          'trans_param': {'cid': -1},
        },
        {'SongName': '有 hash', 'FileHash': 'ok'},
      ];

      final api = MusicApi(_FakeSearchApiClient(fakeData));
      final results = await api.searchSongs('hash_filter');

      expect(results.map((s) => s.title).toList(), ['有 hash']);
    });
  });
}
