import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/core/api_client_interface.dart';
import 'package:shiyin_music/services/music_api.dart';

class _FakeApiClient implements ApiClientInterface {
  _FakeApiClient(this.response);

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
    lastPath = path;
    lastQuery = query;
    return response;
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
  group('MusicApi.searchSuggest 三种响应形态', () {
    test('分组数组（当前 transport 解包后的真实形态）', () async {
      // 抓自本地引擎真实响应（searchtip.kugou.com/v2/getSearchTip）。
      final client = _FakeApiClient([
        {
          'LableName': '',
          'RecordCount': 2,
          'RecordDatas': [
            {'HintInfo': '周杰伦'},
            {'HintInfo': '周杰伦 告白气球'},
          ],
        },
        {
          'LableName': '专辑',
          'RecordDatas': [
            {'HintInfo': '周杰伦 跨时代'},
          ],
        },
      ]);
      final api = MusicApi(client);

      final result = await api.searchSuggest('周杰伦');

      expect(result, ['周杰伦', '周杰伦 告白气球']);
      expect(client.lastPath, '/search/suggest');
      expect(client.lastQuery?['keywords'], '周杰伦');
    });

    test('主分组为空时退到后续分组，并去重', () async {
      final client = _FakeApiClient([
        {'RecordDatas': []},
        {
          'RecordDatas': [
            {'HintInfo': 'A'},
            {'HintInfo': 'A'},
            {'HintInfo': 'B'},
          ],
        },
      ]);
      final api = MusicApi(client);

      expect(await api.searchSuggest('x'), ['A', 'B']);
    });

    test('未解包形态 {data: [...]}', () async {
      final client = _FakeApiClient({
        'data': [
          {
            'RecordDatas': [
              {'HintInfo': '晴天'},
            ],
          },
        ],
      });
      final api = MusicApi(client);

      expect(await api.searchSuggest('晴天'), ['晴天']);
    });

    test('旧平铺形态 {music: [{keyword}]} 仍兼容', () async {
      final client = _FakeApiClient({
        'music': [
          {'keyword': '七里香'},
          {'keyword': ''},
          {'keyword': '夜曲'},
        ],
      });
      final api = MusicApi(client);

      expect(await api.searchSuggest('周杰伦'), ['七里香', '夜曲']);
    });

    test('空/异常响应返回空列表而不是抛错', () async {
      expect(await MusicApi(_FakeApiClient(const [])).searchSuggest('x'), isEmpty);
      expect(await MusicApi(_FakeApiClient(null)).searchSuggest('x'), isEmpty);
      expect(
        await MusicApi(_FakeApiClient(const {'foo': 'bar'})).searchSuggest('x'),
        isEmpty,
      );
    });
  });
}
