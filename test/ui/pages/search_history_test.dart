import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyin_music/controllers/auth_controller.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/services/music_api.dart';
import 'package:shiyin_music/ui/form_factor.dart';
import 'package:shiyin_music/ui/pages/search_page.dart';

class _FakeMusicApi implements MusicApi {
  @override
  Future<List<SearchHotCategory>> searchHotKeywords() async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakePlayerController extends ChangeNotifier implements PlayerController {
  @override
  Song? currentSong;

  @override
  bool isPlaying = false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeAuthController extends ChangeNotifier implements AuthController {
  @override
  bool isLiked(Song song) => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late _FakeMusicApi api;
  late _FakePlayerController player;
  late _FakeAuthController auth;

  setUp(() {
    api = _FakeMusicApi();
    player = _FakePlayerController();
    auth = _FakeAuthController();
    debugDesktopFormFactorOverride = false;
  });

  tearDown(() {
    debugDesktopFormFactorOverride = null;
  });

  Widget buildSubject() {
    return MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(size: Size(390, 844)),
        child: SearchPage(api: api, auth: auth, player: player),
      ),
    );
  }

  group('移动端搜索历史卡片折叠与上限', () {
    testWidgets('历史少于等于 6 条时直接完整显示，不显示展开箭头', (tester) async {
      final history = ['林俊杰', '周杰伦', '甲乙丙丁', '相见恨晚'];
      SharedPreferences.setMockInitialValues({
        'search_history': jsonEncode(history),
      });

      await tester.pumpWidget(buildSubject());
      await tester.pumpAndSettle();

      expect(find.text('搜索历史'), findsOneWidget);
      for (final item in history) {
        expect(find.text(item), findsOneWidget);
      }
      expect(find.byIcon(Icons.keyboard_arrow_down_rounded), findsNothing);
      expect(find.byIcon(Icons.keyboard_arrow_up_rounded), findsNothing);
    });

    testWidgets('历史大于 6 条时默认只展示前 6 条，提供展开按钮', (tester) async {
      final history = List.generate(9, (i) => '历史词$i');
      SharedPreferences.setMockInitialValues({
        'search_history': jsonEncode(history),
      });

      await tester.pumpWidget(buildSubject());
      await tester.pumpAndSettle();

      expect(find.text('搜索历史'), findsOneWidget);

      // 默认只展示前 6 条
      for (var i = 0; i < 6; i++) {
        expect(find.text('历史词$i'), findsOneWidget);
      }
      expect(find.text('历史词6'), findsNothing);
      expect(find.text('历史词7'), findsNothing);
      expect(find.text('历史词8'), findsNothing);

      // 显示向下展开箭头
      final expandBtn = find.byIcon(Icons.keyboard_arrow_down_rounded);
      expect(expandBtn, findsOneWidget);

      // 点击展开
      await tester.tap(expandBtn);
      await tester.pumpAndSettle();

      // 全部 9 条展示
      for (var i = 0; i < 9; i++) {
        expect(find.text('历史词$i'), findsOneWidget);
      }
      // 箭头变为向上收起
      expect(find.byIcon(Icons.keyboard_arrow_up_rounded), findsOneWidget);

      // 再次点击收起
      await tester.tap(find.byIcon(Icons.keyboard_arrow_up_rounded));
      await tester.pumpAndSettle();

      // 恢复为只显示前 6 条
      expect(find.text('历史词0'), findsOneWidget);
      expect(find.text('历史词6'), findsNothing);
      expect(find.byIcon(Icons.keyboard_arrow_down_rounded), findsOneWidget);
    });
  });
}
