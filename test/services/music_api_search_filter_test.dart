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
  group('MusicApi.searchSongs unplayable song filtering', () {
    test('filters dead songs with cid <= 0 and FailProcess == 0', () async {
      final fakeData = {
        'lists': [
          // a) Normal song: trans_param with cid > 0, FailProcess 4
          {
            'SongName': 'Normal Song',
            'FileHash': 'abc',
            'FailProcess': 4,
            'trans_param': {'cid': 12345},
          },
          // b) Dead song: trans_param with cid <= 0, FailProcess 0
          {
            'SongName': 'Dead Song',
            'FileHash': 'def',
            'FailProcess': 0,
            'trans_param': {'cid': -1},
          },
          // c) Missing trans_param
          {
            'SongName': 'Other Song',
            'FileHash': 'ghi',
          },
        ],
      };

      final client = _FakeSearchApiClient(fakeData);
      final api = MusicApi(client);

      final results = await api.searchSongs('test');

      expect(results.map((s) => s.title).toList(), ['Normal Song', 'Other Song']);
      expect(results.map((s) => s.hash).toList(), ['abc', 'ghi']);
    });

    test('edge cases for cid and FailProcess combination', () async {
      final fakeData = [
        // cid == 0 and FailProcess == 0 -> dead
        {
          'SongName': 'Dead Song Zero Cid',
          'FileHash': 'dead0',
          'FailProcess': 0,
          'trans_param': {'cid': 0},
        },
        // cid <= 0 but FailProcess != 0 -> kept
        {
          'SongName': 'Playable Song NonZero FailProcess',
          'FileHash': 'play1',
          'FailProcess': 4,
          'trans_param': {'cid': -1},
        },
        // cid > 0 and FailProcess == 0 -> kept
        {
          'SongName': 'Playable Song Positive Cid',
          'FileHash': 'play2',
          'FailProcess': 0,
          'trans_param': {'cid': 100},
        },
        // trans_param empty map -> kept
        {
          'SongName': 'Playable Empty TransParam',
          'FileHash': 'play3',
          'trans_param': <String, dynamic>{},
        },
      ];

      final client = _FakeSearchApiClient(fakeData);
      final api = MusicApi(client);

      final results = await api.searchSongs('edge_cases');

      expect(
        results.map((s) => s.hash).toList(),
        ['play1', 'play2', 'play3'],
      );
    });
  });
}
