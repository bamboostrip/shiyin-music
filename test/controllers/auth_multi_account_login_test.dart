// issue #18 回归（控制器层）：多账号登录第一步只返回候选账号，不能误把
// 空 session 写进登录态；用户选定账号后第二次登录必须携带 userId 并成功建立会话。
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyin_music/controllers/auth_controller.dart';
import 'package:shiyin_music/core/api_client_interface.dart';
import 'package:shiyin_music/services/cache_service.dart';
import 'package:shiyin_music/services/music_api.dart';

/// 假客户端：/login/cellphone 第一次返回多账号信封，第二次返回成功会话；
/// 其余 GET 返回 refreshProfile / VIP 任务所需的最小可用响应。
class _FakeMultiAccountClient implements ApiClientInterface {
  int loginCalls = 0;
  Map<String, Object?>? lastLoginBody;

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
    return switch (path) {
      '/user/detail' => <String, dynamic>{'userid': '1002', 'nickname': '乙'},
      '/user/vip/detail' => <String, dynamic>{'status': 1},
      '/user/playlist' => <String, dynamic>{
        'userid': '1002',
        'info': <Map<String, dynamic>>[],
      },
      '/youth/month/vip/record' => <String, dynamic>{
        'status': 1,
        'list': <Map<String, dynamic>>[],
      },
      _ => <String, dynamic>{'status': 1},
    };
  }

  @override
  Future<dynamic> getRaw(Uri uri) async => throw UnimplementedError();

  @override
  Future<dynamic> post(
    String path, {
    Map<String, Object?> query = const {},
    Map<String, Object?>? body,
  }) async {
    if (path != '/login/cellphone') {
      return <String, dynamic>{'status': 1};
    }
    loginCalls++;
    lastLoginBody = body;
    if (loginCalls == 1) {
      return <String, dynamic>{
        'status': 0,
        'error_code': 34175,
        'errorCode': 34175,
        'requiresUserSelection': true,
        'message': '该手机号绑定了多个账号，请选择要登录的账号',
        'accounts': [
          {'userId': 1001, 'nickname': '甲'},
          {'userId': 1002, 'nickname': '乙'},
        ],
      };
    }
    return <String, dynamic>{
      'status': 1,
      'error_code': 0,
      'userid': 1002,
      'token': 'token-1002',
      't1': 't1-1002',
    };
  }

  @override
  void close() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('多账号登录：第一步不建立会话，选定账号后二次登录成功', () async {
    SharedPreferences.setMockInitialValues({});
    final client = _FakeMultiAccountClient();
    final api = MusicApi(client);
    final auth = AuthController(api, CacheService());
    addTearDown(auth.dispose);

    final selection = await auth.login('13800138000', '123456');

    expect(selection, isNotNull);
    expect(selection!.requiresUserSelection, isTrue);
    expect(selection.accounts.map((account) => account.userId), ['1001', '1002']);
    expect(auth.isLoggedIn, isFalse, reason: '只返回候选账号时不能建立登录态');
    expect(auth.errorMessage, isNull, reason: '进入选账号流程不应被当成错误');
    expect(client.lastLoginBody?['userId'], isNull, reason: '第一步请求不应携带 userId');

    final login = await auth.login('13800138000', '123456', userId: '1002');

    expect(login, isNotNull);
    expect(login!.requiresUserSelection, isFalse);
    expect(auth.isLoggedIn, isTrue);
    expect(auth.session?.userId, '1002');
    expect(auth.session?.token, 'token-1002');
    expect(client.lastLoginBody?['userId'], '1002', reason: '二次登录必须带回选中的 userId');
    expect(client.loginCalls, 2);
  });
}
