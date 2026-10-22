import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/core/api_client.dart';
import 'package:shiyin_music/core/api_client_interface.dart';
import 'package:shiyin_music/services/music_api.dart';

/// 假客户端：对 /user/playhistory 返回预置响应。
class _FakeHistoryClient implements ApiClientInterface {
  _FakeHistoryClient(this.response);

  final Object? response;
  Object? requestedPath;

  @override
  String? token;
  @override
  String? t1;
  @override
  String? sessionId;

  @override
  Future<dynamic> get(String path,
      [Map<String, Object?> query = const {}]) async {
    requestedPath = path;
    return response;
  }

  @override
  Future<dynamic> getRaw(Uri uri) async => throw UnimplementedError();

  @override
  Future<dynamic> post(String path,
      {Map<String, Object?> query = const {},
      Map<String, Object?>? body}) async {
    throw UnimplementedError();
  }

  @override
  void close() {}
}

void main() {
  group('MusicApi.cloudPlayHistory', () {
    test('请求 GET /user/playhistory 并解析成功响应', () async {
      final client = _FakeHistoryClient({
        'status': 1,
        'list': [
          {'hash': 'h1', 'songname': '晴天', 'singername': '周杰伦', 'time': 100},
        ],
      });
      final api = MusicApi(client);

      final history = await api.cloudPlayHistory();

      expect(client.requestedPath, '/user/playhistory');
      expect(history.totalRecords, 1);
      expect(history.records.first.song.title, '晴天');
    });

    test('根即数组的成功响应同样可解析', () async {
      final api = MusicApi(_FakeHistoryClient([
        {'hash': 'h2', 'songname': '七里香', 'singername': '周杰伦'},
      ]));

      expect((await api.cloudPlayHistory()).totalRecords, 1);
    });

    test('失败信封（status!=1）抛 ApiException 且带错误信息', () async {
      final api = MusicApi(_FakeHistoryClient({
        'status': 0,
        'error_code': 30195,
        'error': '请先登录',
      }));

      await expectLater(
        api.cloudPlayHistory(),
        throwsA(
          isA<ApiException>().having(
            (e) => e.message,
            'message',
            contains('拉取云端播放历史失败'),
          ),
        ),
      );
    });

    test('status==200 的信封按成功处理', () async {
      final api = MusicApi(_FakeHistoryClient({
        'status': 200,
        'songs': [
          {'hash': 'h3', 'songname': '稻香', 'singername': '周杰伦'},
        ],
      }));

      expect((await api.cloudPlayHistory()).totalRecords, 1);
    });
  });
}
