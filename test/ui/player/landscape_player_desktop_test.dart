import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/controllers/auth_controller.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/ui/form_factor.dart';
import 'package:shiyin_music/ui/player/landscape_player.dart';

class _FakePlayerController extends ChangeNotifier
    implements PlayerController {
  @override
  bool isPersonalFmActive = false;

  @override
  bool isLoadingPersonalFm = false;

  @override
  Future<bool> startPersonalFm({List<Song>? initialSongs}) async => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeAuthController extends ChangeNotifier implements AuthController {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  const song = Song(id: '1', title: '测试歌曲', artist: '测试歌手', hash: 'hash1');

  Widget buildHeader() {
    return MaterialApp(
      home: Scaffold(
        body: LandscapeHeader(
          player: _FakePlayerController(),
          auth: _FakeAuthController(),
          song: song,
          onClose: () {},
          compact: false,
          onArtistTap: (_) {},
        ),
      ),
    );
  }

  testWidgets('PC 桌面端形态下，LandscapeHeader 不展示更多操作按钮', (tester) async {
    debugDesktopFormFactorOverride = true;
    addTearDown(() => debugDesktopFormFactorOverride = null);

    await tester.pumpWidget(buildHeader());

    // 验证返回按钮存在
    expect(find.byTooltip('返回'), findsOneWidget);
    // 验证更多操作按钮已在 PC 端被移除，避免与底栏按钮功能冗余
    expect(find.byTooltip('更多'), findsNothing);
    expect(find.byIcon(Icons.more_horiz_rounded), findsNothing);
  });

  testWidgets('移动端/非 PC 形态下，LandscapeHeader 正常展示更多操作按钮', (tester) async {
    debugDesktopFormFactorOverride = false;
    addTearDown(() => debugDesktopFormFactorOverride = null);

    await tester.pumpWidget(buildHeader());

    // 验证返回按钮存在
    expect(find.byTooltip('返回'), findsOneWidget);
    // 验证非桌面形态下依然保留更多按钮
    expect(find.byTooltip('更多'), findsOneWidget);
    expect(find.byIcon(Icons.more_horiz_rounded), findsOneWidget);
  });
}