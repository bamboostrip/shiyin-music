import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyin_music/controllers/auth_controller.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/controllers/theme_controller.dart';
import 'package:shiyin_music/services/identify_service.dart';
import 'package:shiyin_music/services/music_api.dart';
import 'package:shiyin_music/ui/desktop/desktop_title_bar.dart';
import 'package:shiyin_music/ui/pages/search_page.dart';
import 'package:shiyin_music/ui/widgets/home_collapsible_header.dart';

class _FakePlayer implements PlayerController {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeMusicApi implements MusicApi {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeAuthController extends ChangeNotifier implements AuthController {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('HomeBrandHeader 顶栏 Logo 识曲入口', () {
    testWidgets('设置 onTap 时渲染 tooltip 且点击触发回调', (tester) async {
      var identifyTapped = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HomeBrandHeader(
              onTap: () => identifyTapped = true,
            ),
          ),
        ),
      );

      final identifyBtn = find.byTooltip('听歌识曲');
      expect(identifyBtn, findsOneWidget);

      await tester.tap(identifyBtn);
      await tester.pump();

      expect(identifyTapped, isTrue);
    });

    testWidgets('未设置 onTap 时不渲染按钮 tooltip', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: HomeBrandHeader(),
          ),
        ),
      );

      expect(find.byTooltip('听歌识曲'), findsNothing);
    });

    testWidgets('HomeSearchBar 不再内置识曲图标，保持纯粹胶囊搜索框', (tester) async {
      final player = _FakePlayer();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HomeSearchBar(
              player: player,
            ),
          ),
        ),
      );

      expect(find.byIcon(Icons.graphic_eq_rounded), findsNothing);
      expect(find.byIcon(Icons.search_rounded), findsOneWidget);
    });

    testWidgets('HomeCollapsibleHeaderDelegate 顶栏点击品牌 Logo 触发识曲', (tester) async {
      if (!IdentifyService.isSupported) return;

      var identifyTapped = false;
      final player = _FakePlayer();
      final api = _FakeMusicApi();
      final auth = _FakeAuthController();

      final delegate = HomeCollapsibleHeaderDelegate(
        api: api,
        auth: auth,
        player: player,
        sectionIndex: 0,
        onSectionChanged: (_) {},
        onIdentifyTap: () => identifyTapped = true,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CustomScrollView(
              slivers: [
                SliverPersistentHeader(
                  delegate: delegate,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();

      final identifyBtn = find.byTooltip('听歌识曲');
      expect(identifyBtn, findsOneWidget);

      await tester.tap(identifyBtn);
      await tester.pump();

      expect(identifyTapped, isTrue);
    });
  });

  group('DesktopTitleBar 识曲入口', () {
    testWidgets('传入 onOpenIdentify 时渲染按钮并能正确响应点击', (tester) async {
      var opened = false;
      final controller = TextEditingController();
      final focusNode = FocusNode();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DesktopTitleBar(
              controller: controller,
              focusNode: focusNode,
              onOpenIdentify: () => opened = true,
            ),
          ),
        ),
      );

      final identifyBtn = find.byTooltip('听歌识曲');
      expect(identifyBtn, findsOneWidget);

      await tester.tap(identifyBtn);
      await tester.pump();

      expect(opened, isTrue);
    });

    testWidgets('未传入 onOpenIdentify 时不渲染按钮', (tester) async {
      final controller = TextEditingController();
      final focusNode = FocusNode();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DesktopTitleBar(
              controller: controller,
              focusNode: focusNode,
            ),
          ),
        ),
      );

      final identifyBtn = find.byTooltip('听歌识曲');
      expect(identifyBtn, findsNothing);
    });
  });

  group('SearchPage 搜索页识曲入口', () {
    testWidgets('移动端搜索页渲染听歌识曲快捷按钮', (tester) async {
      if (!IdentifyService.isSupported) return;

      final player = _FakePlayer();
      final api = _FakeMusicApi();
      final auth = _FakeAuthController();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SearchPage(
              api: api,
              auth: auth,
              player: player,
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byTooltip('听歌识曲'), findsOneWidget);
      expect(find.byIcon(Icons.graphic_eq_rounded), findsOneWidget);
    });

    testWidgets('车机模式搜索页渲染听歌识曲按钮并包含图标和文字', (tester) async {
      if (!IdentifyService.isSupported) return;

      SharedPreferences.setMockInitialValues({});
      final theme = ThemeController();
      await theme.setCarModeEnabled(true);
      addTearDown(() async {
        await ThemeController.instance.setCarModeEnabled(false);
      });

      tester.view.physicalSize = const Size(1024, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final player = _FakePlayer();
      final api = _FakeMusicApi();
      final auth = _FakeAuthController();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SearchPage(
              api: api,
              auth: auth,
              player: player,
            ),
          ),
        ),
      );
      await tester.pump();

      final identifyBtn = find.widgetWithText(FilledButton, '识曲');
      expect(identifyBtn, findsOneWidget);
      expect(find.byIcon(Icons.graphic_eq_rounded), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '搜索'), findsOneWidget);
    });
  });
}
