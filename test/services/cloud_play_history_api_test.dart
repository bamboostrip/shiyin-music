import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/core/api_client.dart';
import 'package:shiyin_music/core/api_client_interface.dart';
import 'package:shiyin_music/services/music_api.dart';

/// 假客户端：对 /user/playhistory 返回预置响应。
class _FakeHistoryClient implements ApiClientInterface {
  _FakeHistoryClient(this.response);

  final Object? response;
  Object? requestedPath;
  final List<String> requestedPaths = [];

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
    requestedPaths.add(path);
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

    test('status==1 但 error_code 非零的失败信封也抛 ApiException', () async {
      // 引擎失败分支原样透传 root，status 可能仍是 1/200（rust
      // is_success_pair 要求 error_code 缺失或为 0 才算成功），只看
      // status 会把这类失败误读成「云端无记录」的空成功。
      final api = MusicApi(_FakeHistoryClient({
        'status': 1,
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

    test('成功信封显式带 error_code:0 不被误判', () async {
      final api = MusicApi(_FakeHistoryClient({
        'status': 1,
        'error_code': 0,
        'list': [
          {'hash': 'h4', 'songname': '夜曲', 'singername': '周杰伦'},
        ],
      }));

      expect((await api.cloudPlayHistory()).totalRecords, 1);
    });

    test('解析为空时自动探测 listenservice（验收诊断）', () async {
      final client = _FakeHistoryClient({'status': 1, 'list': <Object>[]});
      final api = MusicApi(client);

      expect((await api.cloudPlayHistory()).totalRecords, 0);
      // 探针为 unawaited 后台链，让事件循环跑完。
      for (var i = 0; i < 10; i++) {
        await Future<void>.delayed(Duration.zero);
      }

      expect(client.requestedPaths, contains('/user/listenrank'));
      expect(
        client.requestedPaths.where((p) => p == '/user/listenrank').length,
        2, // list_type 0/1 两档
      );
    });

    test('有数据时不触发探针', () async {
      final client = _FakeHistoryClient({
        'status': 1,
        'list': [
          {'hash': 'h5', 'songname': '晴天', 'singername': '周杰伦'},
        ],
      });
      final api = MusicApi(client);

      await api.cloudPlayHistory();
      for (var i = 0; i < 10; i++) {
        await Future<void>.delayed(Duration.zero);
      }

      expect(client.requestedPaths, ['/user/playhistory']);
    });
  });
}
