// test/ui/widgets/queue_locate_test.dart
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/ui/widgets/queue_locate.dart';

/// 与 queue_sheet 同构的最小列表宿主：40 行 × 行高 56 + 分隔 2。
Widget _harness({required QueueLocateController locate, required GlobalKey activeKey}) {
  return MaterialApp(
    home: Scaffold(
      body: ListView.separated(
        controller: locate.controller,
        shrinkWrap: true,
        // 覆盖全部内容的缓存区，保证目标行 context 常驻（生产端队列面板
        // shrinkWrap 全量构建的等价模拟）。
        scrollCacheExtent: ScrollCacheExtent.pixels(3000),
        itemCount: 40,
        separatorBuilder: (_, _) => const SizedBox(height: 2),
        itemBuilder: (context, i) => KeyedSubtree(
          key: i == 19 ? activeKey : null,
          child: const SizedBox(height: 56, child: Text('row19')),
        ),
      ),
    ),
  );
}

void main() {
  test('初始偏移估算：目标行中心对准假定视口中心', () {
    final locate = QueueLocateController(rowStride: 58, initialIndex: 19);
    // (19 + 0.5) * 58 - 480 / 2 = 891
    expect(locate.controller.initialScrollOffset, 891);
    locate.dispose();
  });

  testWidgets('无入场动画：correctWhenEntranceSettled 首帧后精确居中', (tester) async {
    final locate = QueueLocateController(rowStride: 58, initialIndex: 19);
    final key = GlobalKey();
    await tester.pumpWidget(_harness(locate: locate, activeKey: key));

    final position = locate.controller.position;
    // 估算值先落位（891 ≤ maxScrollExtent 才可见误差校正）。
    expect(position.pixels, 891);

    locate.correctWhenEntranceSettled(null, key);
    await tester.pump();

    // 居中：行顶 19*58 + 行高一半 28 - 视口一半。
    final expected =
        (19 * 58 + 28 - position.viewportDimension / 2).clamp(0.0, position.maxScrollExtent);
    expect(position.pixels, moreOrLessEquals(expected, epsilon: 1));
    locate.dispose();
  });

  testWidgets('入场动画播完后校正；locate 平滑滚回居中；行未挂载不崩溃', (tester) async {
    final locate = QueueLocateController(rowStride: 58, initialIndex: 19);
    final key = GlobalKey();
    await tester.pumpWidget(_harness(locate: locate, activeKey: key));

    // 入场动画进行中调用：先不校正（视口未稳定），播完才居中。
    final entrance = AnimationController(
      vsync: tester,
      duration: const Duration(milliseconds: 250),
    )..forward();
    await tester.pump(const Duration(milliseconds: 50)); // 动画进行中
    locate.correctWhenEntranceSettled(entrance, key);
    await tester.pump();
    expect(locate.controller.position.pixels, 891); // 仍是估算值

    await tester.pumpAndSettle(); // 入场动画播完 → completed → 帧末校正
    final position = locate.controller.position;
    final expected =
        (19 * 58 + 28 - position.viewportDimension / 2).clamp(0.0, position.maxScrollExtent);
    expect(position.pixels, moreOrLessEquals(expected, epsilon: 1));

    // 滚走后 locate 平滑滚回。动画随帧推进，需先 pump 再 await 其 Future。
    locate.controller.jumpTo(0);
    await tester.pump();
    final locating = locate.locate(key);
    await tester.pumpAndSettle();
    await locating;
    expect(position.pixels, moreOrLessEquals(expected, epsilon: 1));

    // 行未挂载（新 key）/ 无 client：no-op 不崩溃。
    await locate.locate(GlobalKey());
    locate.correctWhenEntranceSettled(null, GlobalKey());
    expect(locate.controller.hasClients, isTrue);
    entrance.dispose();
    locate.dispose();
  });
}
