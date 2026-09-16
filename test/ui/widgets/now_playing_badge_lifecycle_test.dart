import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/ui/widgets/now_playing_badge.dart';

/// 读取跳动条当前动画进度（CustomPaint 的 painter 在每帧重建时携带
/// _controller.value，冻结后不再重建、进度保持不变）。
double _progress(WidgetTester tester) {
  final painter =
      tester
          .widget<CustomPaint>(
            find.byWidgetPredicate(
              (w) => w is CustomPaint && w.painter is NowPlayingPainter,
            ),
          )
          .painter as NowPlayingPainter;
  return painter.progress;
}

void main() {
  testWidgets('失焦但可见（inactive）保持跳动，不可见（hidden）冻结，恢复后续动', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: NowPlayingBadge(
            active: true,
            playing: true,
            color: Colors.black,
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));
    final p1 = _progress(tester);
    expect(p1, greaterThan(0));

    // 失焦但窗口可见（桌面多软件并排）：动画继续。
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump(const Duration(milliseconds: 200));
    final p2 = _progress(tester);
    expect(p2, isNot(p1));

    // 窗口不可见（最小化/后台）：冻结，进度不再变化。
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 200));
    final p3 = _progress(tester);
    expect(p3, p2);

    // 回到前台：动画恢复。stop() 后在帧外重启的 Ticker 第一帧只建立
    // 时间基准（elapsed=0），需要额外一帧才推进动画。
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    final p4 = _progress(tester);
    expect(p4, isNot(p3));

    expect(tester.takeException(), isNull);
  });
}
