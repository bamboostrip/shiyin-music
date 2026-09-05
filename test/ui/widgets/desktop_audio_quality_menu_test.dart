import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/ui/form_factor.dart';
import 'package:shiyin_music/ui/widgets/audio_quality_sheet.dart';

void main() {
  tearDown(() {
    debugDesktopFormFactorOverride = null;
  });

  group('showAudioQualitySheet 交互测试', () {
    testWidgets('桌面端传 anchor 时弹出 DesktopAudioQualityMenu 气泡菜单并支持点选',
        (tester) async {
      debugDesktopFormFactorOverride = true;
      AudioQuality? picked;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: Builder(
                builder: (context) => ElevatedButton(
                  onPressed: () async {
                    picked = await showAudioQualitySheet(
                      context: context,
                      selected: AudioQuality.standard,
                      anchor: const Offset(500, 500),
                    );
                  },
                  child: const Text('打开音质菜单'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('打开音质菜单'));
      await tester.pumpAndSettle();

      // 验证桌面气泡菜单渲染
      expect(find.byType(DesktopAudioQualityMenu), findsOneWidget);
      expect(find.text('无损音质'), findsOneWidget);
      expect(find.text('FLAC'), findsOneWidget);
      expect(find.text('高品音质'), findsOneWidget);
      expect(find.text('320K'), findsOneWidget);
      expect(find.text('标准音质'), findsOneWidget);
      expect(find.text('128K'), findsOneWidget);

      // 默认标准音质有 check 图标
      expect(find.byIcon(Icons.check_rounded), findsOneWidget);

      // 点击无损音质
      await tester.tap(find.text('无损音质'));
      await tester.pumpAndSettle();

      expect(picked, AudioQuality.lossless);
      expect(find.byType(DesktopAudioQualityMenu), findsNothing);
    });

    testWidgets('桌面端不传 anchor 时降级为居中 Dialog', (tester) async {
      debugDesktopFormFactorOverride = true;
      AudioQuality? picked;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: Builder(
                builder: (context) => ElevatedButton(
                  onPressed: () async {
                    picked = await showAudioQualitySheet(
                      context: context,
                      selected: AudioQuality.high,
                    );
                  },
                  child: const Text('打开音质弹窗'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('打开音质弹窗'));
      await tester.pumpAndSettle();

      // 居中 Dialog 渲染
      expect(find.byType(Dialog), findsOneWidget);
      expect(find.byType(DesktopAudioQualityMenu), findsNothing);

      // 点击关闭
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();

      expect(picked, isNull);
      expect(find.byType(Dialog), findsNothing);
    });

    testWidgets('移动端形态无论是否传 anchor 均使用 BottomSheet', (tester) async {
      debugDesktopFormFactorOverride = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: Builder(
                builder: (context) => ElevatedButton(
                  onPressed: () => showAudioQualitySheet(
                    context: context,
                    selected: AudioQuality.standard,
                    anchor: const Offset(200, 200),
                  ),
                  child: const Text('打开移动端音质'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('打开移动端音质'));
      await tester.pumpAndSettle();

      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.byType(DesktopAudioQualityMenu), findsNothing);
      expect(find.byType(Dialog), findsNothing);
    });
  });
}
