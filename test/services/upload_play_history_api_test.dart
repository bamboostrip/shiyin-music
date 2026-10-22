import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/core/api_client_interface.dart';
import 'package:shiyin_music/services/music_api.dart';

/// 假客户端：记录 POST 调用并可预置响应/异常。
class _FakeUploadClient implements ApiClientInterface {
  _FakeUploadClient({this.response, this.error});

  final Object? response;
  final Object? error;
  final List<Map<String, Object?>> posts = [];

  @override
  String? token;
  @override
  String? t1;
  @override
  String? sessionId;

  @override
  Future<dynamic> get(String path,
      [Map<String, Object?> query = const {}]) async {
    throw UnimplementedError();
  }

  @override
  Future<dynamic> getRaw(Uri uri) async => throw UnimplementedError();

  @override
  Future<dynamic> post(String path,
      {Map<String, Object?> query = const {},
      Map<String, Object?>? body}) async {
    posts.add({'path': path, ...query});
    if (error != null) throw error!;
    return response;
  }

  @override
  void close() {}
}

void main() {
  group('MusicApi.uploadPlayHistory', () {
    test('POST /playhistory/upload 携带 mixsongid 与默认 play_count=1', () async {
      final client = _FakeUploadClient(response: {'status': 1});
      final api = MusicApi(client);

      await api.uploadPlayHistory(mixSongId: '123456');

      expect(client.posts.single['path'], '/playhistory/upload');
      expect(client.posts.single['mixsongid'], '123456');
      expect(client.posts.single['play_count'], 1);
    });

    test('显式 play_count 透传', () async {
      final client = _FakeUploadClient(response: {'status': 1});
      final api = MusicApi(client);

      await api.uploadPlayHistory(mixSongId: '42', playCount: 2);

      expect(client.posts.single['play_count'], 2);
    });

    test('客户端异常向上抛（由调用方吞错，不在 API 层吞）', () async {
      final api = MusicApi(_FakeUploadClient(error: Exception('网络异常')));

      await expectLater(
        api.uploadPlayHistory(mixSongId: '1'),
        throwsA(isA<Exception>()),
      );
    });
  });
}
