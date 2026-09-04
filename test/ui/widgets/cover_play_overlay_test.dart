import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/ui/widgets/cover_play_overlay.dart';

/// 悬浮播放按钮的 AnimatedOpacity 取值（0 = 隐藏，1 = 浮现）。
double _buttonOpacity(WidgetTester tester) {
  final opacity = tester.widget<AnimatedOpacity>(
    find
        .ancestor(
          of: find.byIcon(Icons.play_arrow_rounded),
          matching: find.byType(AnimatedOpacity),
        )
        .first,
  );
  return opacity.opacity;
}

/// 播放按钮外层 IgnorePointer 是否处于"不拦截点击"状态。
bool _buttonClickable(WidgetTester tester) {
  final ignore = tester.widget<IgnorePointer>(
    find
        .ancestor(
          of: find.byIcon(Icons.play_arrow_rounded),
          matching: find.byType(IgnorePointer),
        )
        .first,
  );
  return !ignore.ignoring;
}

Future<void> _pumpOverlay(
  WidgetTester tester, {
  required VoidCallback onPlay,
  required VoidCallback onCoverTap,
  bool enabled = true,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 120,
            height: 120,
            child: CoverPlayOverlay(
              enabled: enabled,
              onPlay: onPlay,
              cover: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onCoverTap,
                child: const ColoredBox(color: Colors.blueGrey),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('未 hover：蒙层隐藏且不拦截点击，卡片本体可点', (tester) async {
    var playTaps = 0;
    var coverTaps = 0;
    await _pumpOverlay(
      tester,
      onPlay: () => playTaps++,
      onCoverTap: () => coverTaps++,
    );

    expect(_buttonOpacity(tester), 0);
    expect(_buttonClickable(tester), isFalse);

    // 点击封面中心：命中卡片本体，而不是隐藏的播放按钮。
    await tester.tap(find.byType(CoverPlayOverlay));
    await tester.pump();
    expect(coverTaps, 1);
    expect(playTaps, 0);
  });

  testWidgets('hover：蒙层浮现，点击播放按钮直接播放（不触发卡片单击）', (tester) async {
    var playTaps = 0;
    var coverTaps = 0;
    await _pumpOverlay(
      tester,
      onPlay: () => playTaps++,
      onCoverTap: () => coverTaps++,
    );

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.byType(CoverPlayOverlay)));
    await tester.pumpAndSettle();

    expect(_buttonOpacity(tester), 1);
    expect(_buttonClickable(tester), isTrue);

    await tester.tap(find.byIcon(Icons.play_arrow_rounded));
    await tester.pump();
    expect(playTaps, 1);
    expect(coverTaps, 0);

    // 蒙层之下封面其余区域仍可点（卡片单击行为不变）。
    await tester.tapAt(
      tester.getTopLeft(find.byType(CoverPlayOverlay)) + const Offset(10, 10),
    );
    await tester.pump();
    expect(coverTaps, 1);
    expect(playTaps, 1);
  });

  testWidgets('hover 移出：蒙层消失并恢复不拦截点击', (tester) async {
    var playTaps = 0;
    await _pumpOverlay(tester, onPlay: () => playTaps++, onCoverTap: () {});

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.byType(CoverPlayOverlay)));
    await tester.pumpAndSettle();
    expect(_buttonOpacity(tester), 1);

    await mouse.moveTo(Offset.zero);
    await tester.pumpAndSettle();
    expect(_buttonOpacity(tester), 0);
    expect(_buttonClickable(tester), isFalse);
  });

  testWidgets('enabled=false：不注册蒙层，仅渲染封面本体（移动端 / 车机端路径）', (tester) async {
    var playTaps = 0;
    var coverTaps = 0;
    await _pumpOverlay(
      tester,
      onPlay: () => playTaps++,
      onCoverTap: () => coverTaps++,
      enabled: false,
    );

    expect(find.byIcon(Icons.play_arrow_rounded), findsNothing);
    expect(find.byType(AnimatedOpacity), findsNothing);

    await tester.tap(find.byType(CoverPlayOverlay));
    await tester.pump();
    expect(coverTaps, 1);
    expect(playTaps, 0);
  });
}
