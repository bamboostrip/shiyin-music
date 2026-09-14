import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/ui/widgets/cover_play_overlay.dart';
import 'package:shiyin_music/ui/widgets/now_playing_badge.dart';

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
  bool isCurrent = false,
  bool isPlaying = false,
  VoidCallback? onPause,
  VoidCallback? onResume,
  double? buttonSize,
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
              isCurrent: isCurrent,
              isPlaying: isPlaying,
              onPause: onPause,
              onResume: onResume,
              buttonSize: buttonSize,
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

  group('CoverPlayOverlay 播放态与交互矩阵', () {
    testWidgets('isCurrent && isPlaying：未 hover 即可见半透明蒙层与 4 柱 NowPlayingBadge，点击触发 onPause', (tester) async {
      var pauseTaps = 0;
      var playTaps = 0;
      var coverTaps = 0;

      await _pumpOverlay(
        tester,
        isCurrent: true,
        isPlaying: true,
        onPause: () => pauseTaps++,
        onPlay: () => playTaps++,
        onCoverTap: () => coverTaps++,
      );

      // 未 hover 即可见 4 柱跳动音波与半透明蒙层
      final badgeFinder = find.byType(NowPlayingBadge);
      expect(badgeFinder, findsOneWidget);
      final badge = tester.widget<NowPlayingBadge>(badgeFinder);
      expect(badge.active, isTrue);
      expect(badge.playing, isTrue);
      expect(badge.barCount, 4);
      expect(badge.color, Colors.white);

      final maskFinder = find.byWidgetPredicate(
        (widget) => widget is ColoredBox && widget.color == Colors.black38,
      );
      expect(maskFinder, findsOneWidget);
      expect(find.byIcon(Icons.play_arrow_rounded), findsNothing);

      // 点击音波徽章直接触发 onPause
      await tester.tap(badgeFinder);
      await tester.pump();
      expect(pauseTaps, 1);
      expect(playTaps, 0);
      expect(coverTaps, 0);
    });

    testWidgets('isCurrent && isPlaying：hover 时展示「暂停」Tooltip，若未提供 onPause 则回退触发 onPlay', (tester) async {
      var playTaps = 0;
      var coverTaps = 0;

      await _pumpOverlay(
        tester,
        isCurrent: true,
        isPlaying: true,
        onPlay: () => playTaps++,
        onCoverTap: () => coverTaps++,
      );

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(tester.getCenter(find.byType(CoverPlayOverlay)));
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.byTooltip('暂停'), findsOneWidget);

      await tester.tap(find.byType(NowPlayingBadge));
      await tester.pump();
      expect(playTaps, 1);
      expect(coverTaps, 0);
    });

    testWidgets('isCurrent && !isPlaying（暂停态）：未 hover 无蒙层与音波，hover 浮现「继续播放」并触发 onResume', (tester) async {
      var resumeTaps = 0;
      var playTaps = 0;
      var coverTaps = 0;

      await _pumpOverlay(
        tester,
        isCurrent: true,
        isPlaying: false,
        onResume: () => resumeTaps++,
        onPlay: () => playTaps++,
        onCoverTap: () => coverTaps++,
      );

      // 未 hover：无蒙层、无音波，卡片本体可点
      expect(find.byType(NowPlayingBadge), findsNothing);
      final maskFinder = find.byWidgetPredicate(
        (widget) => widget is ColoredBox && widget.color == Colors.black38,
      );
      expect(maskFinder, findsNothing);
      expect(_buttonOpacity(tester), 0);
      expect(_buttonClickable(tester), isFalse);

      await tester.tap(find.byType(CoverPlayOverlay));
      await tester.pump();
      expect(coverTaps, 1);
      expect(resumeTaps, 0);
      expect(playTaps, 0);

      // hover：浮现播放按钮与「继续播放」Tooltip
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(tester.getCenter(find.byType(CoverPlayOverlay)));
      await tester.pumpAndSettle();

      expect(_buttonOpacity(tester), 1);
      expect(_buttonClickable(tester), isTrue);
      expect(find.byTooltip('继续播放'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.play_arrow_rounded));
      await tester.pump();
      expect(resumeTaps, 1);
      expect(playTaps, 0);
    });

    testWidgets('isCurrent && !isPlaying：未提供 onResume 时点击回退触发 onPlay', (tester) async {
      var playTaps = 0;

      await _pumpOverlay(
        tester,
        isCurrent: true,
        isPlaying: false,
        onPlay: () => playTaps++,
        onCoverTap: () {},
      );

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(tester.getCenter(find.byType(CoverPlayOverlay)));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.play_arrow_rounded));
      await tester.pump();
      expect(playTaps, 1);
    });

    testWidgets('!isCurrent：hover 浮现「播放」Tooltip 并触发 onPlay', (tester) async {
      var playTaps = 0;

      await _pumpOverlay(
        tester,
        isCurrent: false,
        isPlaying: false,
        onPlay: () => playTaps++,
        onCoverTap: () {},
      );

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(tester.getCenter(find.byType(CoverPlayOverlay)));
      await tester.pumpAndSettle();

      expect(find.byTooltip('播放'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.play_arrow_rounded));
      await tester.pump();
      expect(playTaps, 1);
    });

    testWidgets('enabled=false 时即便是 isCurrent && isPlaying 也直接返回 cover 本体', (tester) async {
      var pauseTaps = 0;
      var playTaps = 0;
      var coverTaps = 0;

      await _pumpOverlay(
        tester,
        enabled: false,
        isCurrent: true,
        isPlaying: true,
        onPause: () => pauseTaps++,
        onPlay: () => playTaps++,
        onCoverTap: () => coverTaps++,
      );

      expect(find.byType(NowPlayingBadge), findsNothing);
      expect(find.byIcon(Icons.play_arrow_rounded), findsNothing);
      final maskFinder = find.byWidgetPredicate(
        (widget) => widget is ColoredBox && widget.color == Colors.black38,
      );
      expect(maskFinder, findsNothing);

      await tester.tap(find.byType(CoverPlayOverlay));
      await tester.pump();
      expect(coverTaps, 1);
      expect(pauseTaps, 0);
      expect(playTaps, 0);
    });
  });
}
