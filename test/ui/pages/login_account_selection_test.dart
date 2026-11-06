// issue #18 回归（登录页 UI）：多账号响应弹出「选择登录账号」，点选账号后
// 必须带着选中 userId 发起二次登录；二次登录仍要求选账号时必须给出提示。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/controllers/auth_controller.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/services/music_api.dart';
import 'package:shiyin_music/ui/pages/login_page.dart';

class _FakeAuth extends ChangeNotifier implements AuthController {
  _FakeAuth({required this.onLogin});

  final Future<PhoneLoginResult?> Function(String? userId) onLogin;
  final List<String?> loginUserIds = [];

  @override
  bool isLoading = false;
  @override
  String? errorMessage;
  @override
  bool isRestoring = false;
  @override
  bool get isLoggedIn => false;

  @override
  Future<PhoneLoginResult?> login(
    String mobile,
    String code, {
    String? userId,
  }) {
    loginUserIds.add(userId);
    return onLogin(userId);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeMusicApi implements MusicApi {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

PhoneLoginResult _selection() {
  return PhoneLoginResult.accountSelection(
    accounts: const [
      MobileLoginAccount(userId: '1001', nickname: '甲'),
      MobileLoginAccount(userId: '1002', nickname: '乙'),
    ],
    message: '该手机号绑定了多个账号，请选择要登录的账号',
  );
}

Future<void> _pumpAndSubmit(WidgetTester tester, _FakeAuth auth) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: LoginPage(auth: auth, api: _FakeMusicApi()),
      ),
    ),
  );
  expect(find.text('手机号登录'), findsWidgets);

  await tester.enterText(
    find.widgetWithText(TextField, '手机号'),
    '13800138000',
  );
  await tester.enterText(
    find.widgetWithText(TextField, '验证码'),
    '123456',
  );
  await tester.tap(find.text('登录'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('多账号登录会弹出账号选择，点选后携带 userId 二次登录', (tester) async {
    final auth = _FakeAuth(
      onLogin: (userId) async {
        if (userId == null) return _selection();
        return PhoneLoginResult.success(
          const LoginSession(userId: '1002', token: 'token-1002'),
        );
      },
    );

    await _pumpAndSubmit(tester, auth);

    expect(find.text('选择登录账号'), findsOneWidget);
    expect(find.text('UID 1001'), findsOneWidget);
    expect(find.text('UID 1002'), findsOneWidget);
    expect(auth.loginUserIds, [null], reason: '第一步请求不应带 userId');

    await tester.tap(find.text('UID 1002'));
    await tester.pumpAndSettle();

    expect(find.text('选择登录账号'), findsNothing, reason: '选完后弹层应关闭');
    expect(auth.loginUserIds, [null, '1002'], reason: '二次登录必须携带选中 userId');
    expect(tester.takeException(), isNull);
  });

  testWidgets('选定账号后仍要求再选：给出可读提示而不是静默无反馈', (tester) async {
    final auth = _FakeAuth(onLogin: (userId) async => _selection());

    await _pumpAndSubmit(tester, auth);
    await tester.tap(find.text('UID 1002'));
    await tester.pumpAndSettle();

    expect(
      find.text('账号选择未生效，请重新获取验证码后再试'),
      findsOneWidget,
      reason: '二次登录仍返回选账号时必须有提示',
    );
    expect(tester.takeException(), isNull);
  });
}
