// 「歌词动效」选择弹层（issue #26）：移动端底部弹层展示两套样式，
// 选中后把枚举回传给调用方（落盘由 PlayerController 负责）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/ui/form_factor.dart';
import 'package:shiyin_music/ui/widgets/lyric_motion_style_sheet.dart';

void main() {
  setUp(() => debugDesktopFormFactorOverride = false);
  tearDown(() => debugDesktopFormFactorOverride = null);

  testWidgets('移动端底部弹层：选「灵动」后回传 lively', (tester) async {
    LyricMotionStyle? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showLyricMotionStyleSheet(
                  context: context,
                  selected: LyricMotionStyle.standard,
                );
              },
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    expect(find.text('标准'), findsOneWidget);
    expect(find.text('灵动'), findsOneWidget);
    expect(find.text('景深'), findsOneWidget);

    await tester.tap(find.text('灵动'));
    await tester.pumpAndSettle();

    expect(result, LyricMotionStyle.lively);
  });

  testWidgets('桌面形态用对话框，展示三项并可选景深', (tester) async {
    debugDesktopFormFactorOverride = true;
    LyricMotionStyle? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showLyricMotionStyleSheet(
                  context: context,
                  selected: LyricMotionStyle.standard,
                );
              },
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    expect(find.text('歌词动效'), findsOneWidget);
    expect(find.text('景深'), findsOneWidget);

    await tester.tap(find.text('景深'));
    await tester.pumpAndSettle();

    expect(result, LyricMotionStyle.depth);
  });

  testWidgets('选中项显示勾选标记', (tester) async {    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showLyricMotionStyleSheet(
                context: context,
                selected: LyricMotionStyle.lively,
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.check_rounded), findsOneWidget);
  });
}
