import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/controllers/auth_controller.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/services/music_api.dart';
import 'package:shiyin_music/ui/pages/login_page.dart';

class _FakeAuthController extends ChangeNotifier implements AuthController {
  @override
  bool isRestoring = false;
  @override
  bool get isLoggedIn => false;
  @override
  String? errorMessage;
  @override
  bool isLoading = false;

  @override
  bool isLiked(Song song) => false;
  @override
  Future<void> toggleLike(Song song) async {}
  @override
  List<PlaylistSummary> get createdPlaylists => const [];
  @override
  List<PlaylistSummary> get collectedPlaylists => const [];
  @override
  List<PlaylistSummary> get collectedAlbums => const [];
  @override
  PlaylistSummary? get likedPlaylist => null;
  @override
  int get likedCount => 0;
  @override
  UserProfile? get profile => null;
  @override
  UserVipInfo? get vipInfo => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeMusicApi implements MusicApi {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _pumpLoginPage(WidgetTester tester) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: LoginPage(auth: _FakeAuthController(), api: _FakeMusicApi()),
      ),
    ),
  );
  // 默认短信登录 tab：手机号/验证码输入卡片直接可见
  //（「手机号登录」既是 tab 标签也是卡片标题，出现两次）。
  expect(find.text('手机号登录'), findsWidgets);
}

void main() {
  testWidgets('短信登录使用标准 TextField：hint 可见、输入后隐藏', (tester) async {
    await _pumpLoginPage(tester);

    expect(find.byType(TextField), findsNWidgets(2));
    final mobileField = find.widgetWithText(TextField, '手机号');
    final codeField = find.widgetWithText(TextField, '验证码');
    expect(mobileField, findsOneWidget);
    expect(codeField, findsOneWidget);
    expect(find.text('手机号'), findsOneWidget);
    expect(find.text('验证码'), findsOneWidget);

    // 输入手机号后内容写入 controller 并渲染；hint 走 AnimatedOpacity
    // 淡出（widget 仍留在树里），故断言其透明度而非 findsNothing。
    await tester.enterText(mobileField, '13800138000');
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(mobileField).controller?.text,
        '13800138000');
    expect(find.text('13800138000'), findsOneWidget);
    expect(
      find
          .text('手机号')
          .evaluate()
          .single
          .findAncestorWidgetOfExactType<AnimatedOpacity>()
          ?.opacity,
      0.0,
    );

    // 验证码框同样可用。
    await tester.enterText(codeField, '123456');
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(codeField).controller?.text, '123456');
    expect(find.text('123456'), findsOneWidget);
    expect(
      find
          .text('验证码')
          .evaluate()
          .single
          .findAncestorWidgetOfExactType<AnimatedOpacity>()
          ?.opacity,
      0.0,
    );
  });

  testWidgets('验证码框持有焦点时切后台再回来：焦点恢复且不抛异常', (tester) async {
    await _pumpLoginPage(tester);

    final codeField = find.widgetWithText(TextField, '验证码');
    await tester.tap(codeField);
    await tester.pump();
    final focusNode = tester.widget<TextField>(codeField).focusNode!;
    expect(focusNode.hasFocus, isTrue);

    // 完整生命周期环：resumed → inactive → hidden → paused →
    // hidden → inactive → resumed（框架校验合法迁移序列）。
    // 回到 resumed 时生命周期回调会 unfocus + 下一帧 refocus，
    // 强制重建输入连接。
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(focusNode.hasFocus, isTrue);
  });
}
