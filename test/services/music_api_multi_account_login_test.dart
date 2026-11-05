// issue #18 回归：一个手机号绑定多个酷狗账号时，后端（上游 KA Music API /
// 本仓库 Rust 引擎）返回账号选择信封，前端必须进入「选择登录账号」流程，
// 并在用户选定后把 userId 带回 /login/cellphone 完成二次登录。
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/core/api_client_interface.dart';
import 'package:shiyin_music/services/music_api.dart';

/// 只服务 /login/cellphone 的假客户端：按调用次数依次返回脚本化响应，
/// 并记录最后一次请求体，用于断言 userId 透传。
class _FakeLoginClient implements ApiClientInterface {
  _FakeLoginClient(this.responses);

  final List<Map<String, dynamic>> responses;
  final List<Map<String, Object?>> bodies = [];

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
  ]) async => throw UnimplementedError();

  @override
  Future<dynamic> getRaw(Uri uri) async => throw UnimplementedError();

  @override
  Future<dynamic> post(
    String path, {
    Map<String, Object?> query = const {},
    Map<String, Object?>? body,
  }) async {
    expect(path, '/login/cellphone');
    bodies.add(body ?? const {});
    return responses[bodies.length - 1];
  }

  @override
  void close() {}
}

void main() {
  test('多账号响应归一后进入账号选择，并解析候选账号', () async {
    final client = _FakeLoginClient([
      {
        'status': 0,
        'error_code': 34175,
        'errorCode': 34175,
        'requiresUserSelection': true,
        'message': '该手机号绑定了多个账号，请选择要登录的账号',
        'accounts': [
          {
            'userId': 1001,
            'nickname': '甲',
            'pic': 'https://img.example/1.jpg',
            'appId': 3116,
            'username': 'acc1',
          },
          {
            'userId': '1002',
            'nickname': '乙',
            'appId': '1001',
          },
        ],
      },
    ]);

    final result = await MusicApi(client).loginWithPhone(
      mobile: '13800138000',
      code: '123456',
    );

    expect(result.requiresUserSelection, isTrue);
    expect(result.errorCode, 34175);
    expect(result.message, '该手机号绑定了多个账号，请选择要登录的账号');
    expect(result.accounts, hasLength(2));
    expect(result.accounts[0].userId, '1001');
    expect(result.accounts[0].nickname, '甲');
    expect(result.accounts[0].appId, 3116);
    expect(result.accounts[1].userId, '1002');
    // 首次请求不应带 userId（由用户在弹层里选）。
    expect(client.bodies.single.containsKey('userId'), isFalse);
  });

  test('选定账号后把 userId 带回登录请求并返回会话', () async {
    final client = _FakeLoginClient([
      {
        'status': 0,
        'error_code': 34175,
        'accounts': [
          {'userId': 1001, 'nickname': '甲'},
          {'userId': 1002, 'nickname': '乙'},
        ],
      },
      {
        'status': 1,
        'error_code': 0,
        'userid': 1002,
        'token': 'token-1002',
        't1': 't1-1002',
      },
    ]);

    final api = MusicApi(client);
    final selection = await api.loginWithPhone(
      mobile: '13800138000',
      code: '123456',
    );
    expect(selection.requiresUserSelection, isTrue);

    final result = await api.loginWithPhone(
      mobile: '13800138000',
      code: '123456',
      userId: selection.accounts[1].userId,
    );

    expect(result.requiresUserSelection, isFalse);
    expect(result.session?.userId, '1002');
    expect(result.session?.token, 'token-1002');
    expect(client.bodies.last['mobile'], '13800138000');
    expect(client.bodies.last['code'], '123456');
    expect(client.bodies.last['userId'], '1002');
  });

  test('兼容仅带 error_code + accounts 的旧后端信封', () async {
    final client = _FakeLoginClient([
      {
        'status': 0,
        'error_code': 34175,
        'accounts': [
          {'userid': 1001, 'nickname': '甲'},
        ],
      },
    ]);

    final result = await MusicApi(
      client,
    ).loginWithPhone(mobile: '13800138000', code: '123456');

    expect(result.requiresUserSelection, isTrue);
    expect(result.accounts.single.userId, '1001');
  });
}
