// test/ui/widgets/queue_locate_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/ui/widgets/queue_locate.dart';

/// 与 queue_sheet 同构的最小列表宿主：40 行 × 行高 56 + 分隔 2。
/// 刻意保持懒构建（仅 shrinkWrap 模拟 sheet 结构，不做保活）：
/// 目标行滚出视口 + 缓存区后即卸载——定位器必须在此生产行为下工作。
Widget _harness({required QueueLocateController locate, required GlobalKey activeKey}) {
  return MaterialApp(
    home: Scaffold(
      body: ListView.separated(
        controller: locate.controller,
        shrinkWrap: true,
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

  testWidgets('无入场动画：correctWhenEntranceSettled 两段式精确居中', (tester) async {
    final locate = QueueLocateController(rowStride: 58, initialIndex: 19);
    final key = GlobalKey();
    await tester.pumpWidget(_harness(locate: locate, activeKey: key));

    final position = locate.controller.position;
    // 估算值先落位（891 ≤ maxScrollExtent 才可见误差校正）。
    expect(position.pixels, 891);

    locate.correctWhenEntranceSettled(null, key);
    await tester.pump(); // 第一段：jump 到真实视口估算位。
    await tester.pump(); // 第二段：目标行挂载后 ensureVisible 精修。

    // 居中：行顶 19*58 + 行高一半 28 - 视口一半。
    final expected =
        (19 * 58 + 28 - position.viewportDimension / 2).clamp(0.0, position.maxScrollExtent);
    expect(position.pixels, moreOrLessEquals(expected, epsilon: 1));
    locate.dispose();
  });

  testWidgets('入场动画播完后两段式校正；locate 瞬移+精修；行未挂载停在估算位', (tester) async {
    final locate = QueueLocateController(rowStride: 58, initialIndex: 19);
    final key = GlobalKey();
    await tester.pumpWidget(_harness(locate: locate, activeKey: key));

    // 入场动画进行中调用：先不校正（视口未稳定），播完才两段式居中。
    final entrance = AnimationController(
      vsync: tester,
      duration: const Duration(milliseconds: 250),
    )..forward();
    await tester.pump(const Duration(milliseconds: 50)); // 动画进行中
    locate.correctWhenEntranceSettled(entrance, key);
    await tester.pump();
    expect(locate.controller.position.pixels, 891); // 仍是估算值

    await tester.pumpAndSettle(); // 入场动画播完 → jump 估算 + 精修居中
    final position = locate.controller.position;
    final expected =
        (19 * 58 + 28 - position.viewportDimension / 2).clamp(0.0, position.maxScrollExtent);
    expect(position.pixels, moreOrLessEquals(expected, epsilon: 1));

    // 滚走后行被懒构建卸载：locate 先瞬移到真实视口估算位，再精修居中。
    locate.controller.jumpTo(0);
    await tester.pump();
    expect(key.currentContext, isNull); // 懒构建：目标行确已卸载
    final locating = locate.locate(19, key);
    final estimate =
        ((19 + 0.5) * 58 - position.viewportDimension / 2).clamp(0.0, position.maxScrollExtent);
    expect(position.pixels, moreOrLessEquals(estimate, epsilon: 1)); // 第一段：瞬移
    await tester.pumpAndSettle(); // 第二段：行重新挂载 → 250ms 平滑精修
    await locating;
    expect(position.pixels, moreOrLessEquals(expected, epsilon: 1));

    // 行从未挂载（新 key）：locate 停在估算位返回，不崩溃。
    final missLocating = locate.locate(19, GlobalKey());
    await tester.pump();
    await missLocating;
    expect(position.pixels, moreOrLessEquals(estimate, epsilon: 1));

    locate.correctWhenEntranceSettled(null, GlobalKey()); // 未挂载 key：不崩
    expect(locate.controller.hasClients, isTrue);
    entrance.dispose();
    locate.dispose();
  });
}
