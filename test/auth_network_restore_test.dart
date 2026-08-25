import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyin_music/controllers/auth_controller.dart';
import 'package:shiyin_music/core/api_client_interface.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/services/cache_service.dart';
import 'package:shiyin_music/services/music_api.dart';
import 'package:shiyin_music/services/network_monitor.dart';

/// 假客户端：按 path 路由 refreshProfile / VIP 领取涉及的端点，记录调用。
class _FakeAuthClient implements ApiClientInterface {
  final paths = <String>[];

  @override
  String? token;
  @override
  String? t1;
  @override
  String? sessionId;

  @override
  Future<dynamic> get(String path, [Map<String, Object?> query = const {}]) async {
    paths.add(path);
    return switch (path) {
      '/user/detail' => {'userid': 'u1', 'nickname': 'nick'},
      '/user/vip/detail' => {'status': 1},
      '/user/playlist' => {'userid': 'u1', 'info': <Map<String, dynamic>>[]},
      '/youth/month/vip/record' => {'status': 1, 'list': <Map<String, dynamic>>[]},
      '/youth/day/vip' => {'status': 1},
      '/youth/day/vip/upgrade' => {'status': 1},
      _ => throw ArgumentError('unexpected path: $path'),
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('网络恢复后已登录用户自动刷新资料/VIP 状态并补跑每日领取', () async {
    SharedPreferences.setMockInitialValues({});
    final client = _FakeAuthClient();
    final api = MusicApi(client);
    final auth = AuthController(api, CacheService());
    addTearDown(auth.dispose);
    auth.session = LoginSession(userId: 'u1', token: 't', sessionId: 's');
    api.setSession(auth.session);

    NetworkMonitor.instance.debugSimulateRestored();
    await pumpEventQueue();

    expect(client.paths, contains('/user/detail'), reason: '应刷新用户资料');
    expect(client.paths, contains('/user/vip/detail'), reason: '应刷新 VIP 状态');
    expect(
      client.paths,
      contains('/youth/month/vip/record'),
      reason: '断网启动漏掉的每日 VIP 领取应补跑（先查领取记录）',
    );
  });

  test('网络恢复后未登录不触发任何刷新', () async {
    SharedPreferences.setMockInitialValues({});
    final client = _FakeAuthClient();
    final auth = AuthController(MusicApi(client), CacheService());
    addTearDown(auth.dispose);

    NetworkMonitor.instance.debugSimulateRestored();
    await pumpEventQueue();

    expect(client.paths, isEmpty);
  });
}
