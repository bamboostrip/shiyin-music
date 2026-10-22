import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/controllers/auth_controller.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/core/api_client_interface.dart';
import 'package:shiyin_music/services/music_api.dart';
import 'package:shiyin_music/ui/pages/time_machine_page.dart';

class _FakeClient implements ApiClientInterface {
  _FakeClient({this.response, this.error});
  final Object? response;
  final Object? error;
  String? requestedPath;

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
    if (error != null) throw error!;
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

class _FakeAuth extends Fake implements AuthController {
  _FakeAuth({required this.loggedIn});
  final bool loggedIn;
  @override
  bool get isLoggedIn => loggedIn;
}

class _FakePlayer extends Fake implements PlayerController {}

Widget _wrap(Widget child) => MaterialApp(home: child);

void main() {
  testWidgets('未登录时展示登录引导，不发请求', (tester) async {
    final client = _FakeClient(response: {'status': 1, 'list': <Object>[]});

    await tester.pumpWidget(_wrap(TimeMachinePage(
      api: MusicApi(client),
      auth: _FakeAuth(loggedIn: false),
      player: _FakePlayer(),
    )));
    await tester.pumpAndSettle();

    expect(find.text('登录后查看你的听歌时光机'), findsOneWidget);
    expect(client.requestedPath, isNull);
  });

  testWidgets('已登录 + 空云端记录时展示空态文案', (tester) async {
    await tester.pumpWidget(_wrap(TimeMachinePage(
      api: MusicApi(_FakeClient(response: {'status': 1, 'list': <Object>[]})),
      auth: _FakeAuth(loggedIn: true),
      player: _FakePlayer(),
    )));
    await tester.pumpAndSettle();

    expect(find.text('云端还没有听歌记录'), findsOneWidget);
  });

  testWidgets('已登录 + 请求失败时展示错误态与重试按钮', (tester) async {
    await tester.pumpWidget(_wrap(TimeMachinePage(
      api: MusicApi(_FakeClient(error: Exception('网络异常'))),
      auth: _FakeAuth(loggedIn: true),
      player: _FakePlayer(),
    )));
    await tester.pumpAndSettle();

    expect(find.text('重试'), findsOneWidget);
    expect(find.byIcon(Icons.refresh_rounded), findsOneWidget);
  });
}
