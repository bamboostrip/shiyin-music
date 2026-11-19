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

/// 步长失配宿主：无分隔、实际行高 [rowHeight] ≠ 构造期标称步长，
/// 与字体缩放（行高随 TextScaler 增大）数学等价且可控。
/// 终审探针场景（长队列 + 小视口）用 [viewportHeight] 收窄视口。
Widget _mismatchHarness({
  required QueueLocateController locate,
  required GlobalKey activeKey,
  required double rowHeight,
  int itemCount = 40,
  int activeIndex = 19,
  double? viewportHeight,
}) {
  final list = ListView.builder(
    controller: locate.controller,
    itemCount: itemCount,
    itemBuilder: (context, i) => KeyedSubtree(
      key: i == activeIndex ? activeKey : null,
      child: SizedBox(height: rowHeight, child: Text('row$activeIndex')),
    ),
  );
  return MaterialApp(
    home: Scaffold(
      body: viewportHeight == null ? list : SizedBox(height: viewportHeight, child: list),
    ),
  );
}

void main() {
  test('初始偏移估算：目标行中心对准假定视口中心（默认 360）', () {
    final locate = QueueLocateController(rowStride: 58, initialIndex: 19);
    // (19 + 0.5) * 58 - 360 / 2 = 951
    expect(locate.controller.initialScrollOffset, 951);
    locate.dispose();
  });

  testWidgets('无入场动画：correctWhenEntranceSettled 两段式精确居中', (tester) async {
    final locate = QueueLocateController(rowStride: 58, initialIndex: 19);
    final key = GlobalKey();
    await tester.pumpWidget(_harness(locate: locate, activeKey: key));

    final position = locate.controller.position;
    expect(position.pixels, 951);

    locate.correctWhenEntranceSettled(null, key, index: 19, itemCount: 40);
    await tester.pump(); // 第一段：实测步长 jump 到估算位。
    await tester.pump(); // 第二段：目标行挂载后 ensureVisible 精修。

    // 居中：行顶 19*58 + 行高一半 28 - 视口一半。估算位与精修目标仅差
    // 个位数 px，容差 0.1 才能检测第二段（精修）丢失。
    final expected =
        (19 * 58 + 28 - position.viewportDimension / 2).clamp(0.0, position.maxScrollExtent);
    expect(position.pixels, moreOrLessEquals(expected, epsilon: 0.1));
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
    locate.correctWhenEntranceSettled(entrance, key, index: 19, itemCount: 40);
    await tester.pump();
    expect(locate.controller.position.pixels, 951); // 仍是估算值

    await tester.pumpAndSettle(); // 入场动画播完 → jump 估算 + 精修居中
    final position = locate.controller.position;
    final expected =
        (19 * 58 + 28 - position.viewportDimension / 2).clamp(0.0, position.maxScrollExtent);
    expect(position.pixels, moreOrLessEquals(expected, epsilon: 0.1));

    // 滚走后行被懒构建卸载：locate 先瞬移到实测步长估算位，再精修居中。
    locate.controller.jumpTo(0);
    await tester.pump();
    expect(key.currentContext, isNull); // 懒构建：目标行确已卸载
    final locating = locate.locate(19, key, itemCount: 40);
    // 第一段落点 = 实测步长 (maxScrollExtent + viewport) / itemCount 的居中
    // 估算（与实现同式镜像；终位由下方几何断言把关）。
    final measured = (position.maxScrollExtent + position.viewportDimension) / 40;
    final estimate =
        ((19 + 0.5) * measured - position.viewportDimension / 2).clamp(0.0, position.maxScrollExtent);
    expect(position.pixels, moreOrLessEquals(estimate, epsilon: 0.1)); // 第一段：瞬移
    await tester.pumpAndSettle(); // 第二段：行重新挂载 → 250ms 平滑精修
    await locating;
    expect(position.pixels, moreOrLessEquals(expected, epsilon: 0.1));

    // 行从未挂载（新 key）：此刻在 830（19 行精修位），对 fresh key 定位到
    // 0 行——估算为负 clamp 后为 0。jump 应发生且无精修，精确停在估算位 0
    // （可区分「无操作」与「jump 后未精修」）。重试 3 轮各需一帧，
    // 用 pumpAndSettle 驱动完所有轮次再 await。
    final missLocating = locate.locate(0, GlobalKey(), itemCount: 40);
    await tester.pumpAndSettle();
    await missLocating;
    expect(position.pixels, 0.0);

    locate.correctWhenEntranceSettled(null, GlobalKey(), index: 19, itemCount: 40); // 不崩
    expect(locate.controller.hasClients, isTrue);
    entrance.dispose();
    locate.dispose();
  });

  testWidgets('入场动画倒放（弹层关闭）：撤监听不校正', (tester) async {
    final locate = QueueLocateController(rowStride: 58, initialIndex: 19);
    final key = GlobalKey();
    await tester.pumpWidget(_harness(locate: locate, activeKey: key));

    final entrance = AnimationController(
      vsync: tester,
      duration: const Duration(milliseconds: 250),
    )..forward();
    await tester.pump(const Duration(milliseconds: 50));
    locate.correctWhenEntranceSettled(entrance, key, index: 19, itemCount: 40);
    entrance.reverse(); // 弹层关闭：入场动画倒放 → dismissed
    await tester.pumpAndSettle();

    expect(locate.controller.position.pixels, 951); // dismissed：未校正
    entrance.dispose();
    locate.dispose();
  });

  testWidgets('步长失配（行高 70 / 标称 58，App 字体 1.3 档）：locate 实测步长精确居中', (tester) async {
    final locate = QueueLocateController(rowStride: 58, initialIndex: 19);
    final key = GlobalKey();
    await tester.pumpWidget(_mismatchHarness(locate: locate, activeKey: key, rowHeight: 70));

    final locating = locate.locate(19, key, itemCount: 40);
    await tester.pumpAndSettle();
    await locating;

    expect(key.currentContext, isNotNull); // 探针模板：行最终必须挂载
    final position = locate.controller.position;
    expect(position.pixels, moreOrLessEquals(19 * 70 + 35 - position.viewportDimension / 2, epsilon: 0.1));
    locate.dispose();
  });

  testWidgets('步长失配（行高 90 / 标称 74，车机档）：locate 实测步长精确居中', (tester) async {
    final locate = QueueLocateController(rowStride: 74, initialIndex: 19);
    final key = GlobalKey();
    await tester.pumpWidget(_mismatchHarness(locate: locate, activeKey: key, rowHeight: 90));

    final locating = locate.locate(19, key, itemCount: 40);
    await tester.pumpAndSettle();
    await locating;

    expect(key.currentContext, isNotNull);
    final position = locate.controller.position;
    expect(position.pixels, moreOrLessEquals(19 * 90 + 45 - position.viewportDimension / 2, epsilon: 0.1));
    locate.dispose();
  });

  testWidgets('步长失配 + 长队列小视口（终审探针：439 行第 300 行、视口 350）', (tester) async {
    final locate = QueueLocateController(rowStride: 52, initialIndex: 300);
    final key = GlobalKey();
    await tester.pumpWidget(
      _mismatchHarness(
        locate: locate,
        activeKey: key,
        rowHeight: 67,
        itemCount: 439,
        activeIndex: 300,
        viewportHeight: 350,
      ),
    );

    final locating = locate.locate(300, key, itemCount: 439);
    await tester.pumpAndSettle();
    await locating;

    // 固定步长 52 会落在 ~15451（距目标行 ~4600px，行不挂载、精修被跳过）；
    // 实测步长 67 一轮收敛到目标邻域并精修。
    expect(key.currentContext, isNotNull);
    final position = locate.controller.position;
    expect(
      position.pixels,
      moreOrLessEquals(300 * 67 + 33.5 - position.viewportDimension / 2, epsilon: 0.1),
    );
    locate.dispose();
  });

  testWidgets('步长失配下 correctWhenEntranceSettled：入场播完后精确居中', (tester) async {
    final locate = QueueLocateController(rowStride: 58, initialIndex: 19);
    final key = GlobalKey();
    await tester.pumpWidget(_mismatchHarness(locate: locate, activeKey: key, rowHeight: 70));

    final entrance = AnimationController(
      vsync: tester,
      duration: const Duration(milliseconds: 250),
    )..forward();
    await tester.pump(const Duration(milliseconds: 50));
    locate.correctWhenEntranceSettled(entrance, key, index: 19, itemCount: 40);
    await tester.pumpAndSettle(); // 入场播完 → 实测步长 jump + 精修

    expect(key.currentContext, isNotNull);
    final position = locate.controller.position;
    expect(position.pixels, moreOrLessEquals(19 * 70 + 35 - position.viewportDimension / 2, epsilon: 0.1));
    entrance.dispose();
    locate.dispose();
  });
}
