import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/services/identify_service.dart';
import 'package:shiyin_music/ui/desktop/desktop_title_bar.dart';
import 'package:shiyin_music/ui/widgets/home_collapsible_header.dart';

class _FakePlayer implements PlayerController {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('HomeSearchBar 识曲入口', () {
    testWidgets('在支持平台上渲染识曲按钮且点击可触发识曲', (tester) async {
      if (!IdentifyService.isSupported) return;

      var identifyTapped = false;
      final player = _FakePlayer();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HomeSearchBar(
              player: player,
              onIdentifyTap: () => identifyTapped = true,
            ),
          ),
        ),
      );

      final identifyBtn = find.byTooltip('听歌识曲');
      expect(identifyBtn, findsOneWidget);
      expect(find.byIcon(Icons.graphic_eq_rounded), findsOneWidget);

      await tester.tap(identifyBtn);
      await tester.pump();

      expect(identifyTapped, isTrue);
    });

    testWidgets('无 player 时不渲染识曲按钮', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: HomeSearchBar(),
          ),
        ),
      );

      expect(find.byTooltip('听歌识曲'), findsNothing);
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

  group('车机顶栏识曲入口', () {
    testWidgets('车机模式下渲染识曲按钮且图标展示正常', (tester) async {
      if (!IdentifyService.isSupported) return;

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

      expect(find.byIcon(Icons.graphic_eq_rounded), findsOneWidget);
    });
  });
}
