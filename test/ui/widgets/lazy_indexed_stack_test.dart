import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/ui/widgets/lazy_indexed_stack.dart';

/// 计数用测试 tab：记录 initState / build / dispose 次数。
/// 「已建记录」由 init 计数体现：保活中的 tab 在父级重建时不得重跑
/// initState；被淘汰后重进则 init 计数 +1（State 重建）。
class _CountedTab extends StatefulWidget {
  const _CountedTab(this.label, this.counters);

  final String label;
  final Map<String, int> counters;

  @override
  State<_CountedTab> createState() => _CountedTabState();
}

class _CountedTabState extends State<_CountedTab> {
  void _bump(String key) =>
      widget.counters[key] = (widget.counters[key] ?? 0) + 1;

  @override
  void initState() {
    super.initState();
    _bump('init');
  }

  @override
  void dispose() {
    _bump('dispose');
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _bump('build');
    return Center(child: Text(widget.label));
  }
}

// find.text 默认 skipOffstage:true（跳过 Offstage 子树）。IndexedStack
// 的非当前 child 处于 Offstage，因此：
// - _visible 找得到 = 已建且当前可见；
// - _built 找得到（含 offstage）= 已建保活中；
// - _built 找不到 = 已被淘汰（连 Element 都不在树里）。
Finder _visible(String label) => find.text(label);
Finder _built(String label) => find.text(label, skipOffstage: false);

/// 每次调用都创建全新的 child widget 实例（与 desktop_shell 的
/// _tabsRevision 整树重建同型：类型/位置不变 → Element/State 复用，
/// 只有 widget 配置换新），以此模拟父级不断 setState 重建。
Widget _host({required int index, required List<Map<String, int>> counters}) {
  return MaterialApp(
    home: Scaffold(
      body: LazyIndexedStack(
        index: index,
        children: [
          for (var i = 0; i < counters.length; i++)
            _CountedTab('tab$i', counters[i]),
        ],
      ),
    ),
  );
}

int _of(Map<String, int> counters, String key) => counters[key] ?? 0;

void main() {
  testWidgets('4 children 依次访问 0,1,2,3：最旧的 0 被淘汰', (tester) async {
    final counters = List.generate(4, (_) => <String, int>{});
    await tester.pumpWidget(_host(index: 0, counters: counters));
    await tester.pumpWidget(_host(index: 1, counters: counters));
    expect(_built('tab0'), findsOneWidget); // 保活中（offstage 但在树里）
    await tester.pumpWidget(_host(index: 2, counters: counters));
    expect(_built('tab0'), findsOneWidget); // 3 个以内不淘汰
    await tester.pumpWidget(_host(index: 3, counters: counters));

    // 上限 3：最久未访问的 tab0 淘汰——其子树整体从树中消失，State 释放。
    expect(_built('tab0'), findsNothing);
    expect(_visible('tab3'), findsOneWidget);
    expect(_of(counters[0], 'dispose'), 1);
    // 其余三个仍保活：内容还在树里、未发生 dispose。
    expect(_built('tab1'), findsOneWidget);
    expect(_built('tab2'), findsOneWidget);
    expect(_of(counters[1], 'dispose'), 0);
    expect(_of(counters[2], 'dispose'), 0);
  });

  testWidgets('回到被淘汰的 0：重新构建且成为当前可见', (tester) async {
    final counters = List.generate(4, (_) => <String, int>{});
    await tester.pumpWidget(_host(index: 0, counters: counters));
    await tester.pumpWidget(_host(index: 1, counters: counters));
    await tester.pumpWidget(_host(index: 2, counters: counters));
    await tester.pumpWidget(_host(index: 3, counters: counters));
    expect(_of(counters[0], 'init'), 1);

    await tester.pumpWidget(_host(index: 0, counters: counters));

    // tab0 重建：initState 重跑（重进走 SWR/磁盘缓存恢复）。
    expect(_visible('tab0'), findsOneWidget);
    expect(_of(counters[0], 'init'), 2);
    // 让位淘汰次旧的 tab1（LRU：tab0 刚被访问，不可能是它）。
    expect(_built('tab1'), findsNothing);
    expect(_of(counters[1], 'dispose'), 1);
    // IndexedStack 当前显示 index 指向 tab0。
    final stack = tester.widget<IndexedStack>(find.byType(IndexedStack));
    expect(stack.index, 0);
  });

  testWidgets('反复切换时当前显示 index 永不淘汰', (tester) async {
    final counters = List.generate(4, (_) => <String, int>{});
    await tester.pumpWidget(_host(index: 0, counters: counters));
    const visits = [1, 2, 3, 0, 1, 2, 3, 0, 2];
    for (final next in visits) {
      final disposeBefore = [
        for (final c in counters) _of(c, 'dispose'),
      ];
      await tester.pumpWidget(_host(index: next, counters: counters));
      // 当前显示的 tab 必须在树中且可见。
      expect(_visible('tab$next'), findsOneWidget);
      // 本帧允许按 LRU 淘汰「最旧的其它」child，但绝不可能是当前 index：
      // 同帧发生 dispose 的下标若等于 next 即违约。
      for (var i = 0; i < counters.length; i++) {
        final evictedThisFrame = _of(counters[i], 'dispose') > disposeBefore[i];
        if (evictedThisFrame) {
          expect(i, isNot(next),
              reason: '当前显示 index 永不淘汰被违反：tab$i 在切到它的同一帧被淘汰');
        }
      }
    }
  });

  testWidgets('2 children 形态永不触发淘汰', (tester) async {
    final counters = List.generate(2, (_) => <String, int>{});
    await tester.pumpWidget(_host(index: 0, counters: counters));
    await tester.pumpWidget(_host(index: 1, counters: counters));
    await tester.pumpWidget(_host(index: 0, counters: counters));
    await tester.pumpWidget(_host(index: 1, counters: counters));
    await tester.pumpWidget(_host(index: 0, counters: counters));

    // 移动端 首页/我的 两页形态：怎么切都不淘汰。
    for (final c in counters) {
      expect(_of(c, 'dispose'), 0);
      expect(_of(c, 'init'), 1);
    }
    expect(_visible('tab0'), findsOneWidget);
    expect(_built('tab1'), findsOneWidget);
  });

  testWidgets('父级重建（didUpdateWidget）不丢失已建记录与访问序', (tester) async {
    final counters = List.generate(4, (_) => <String, int>{});
    await tester.pumpWidget(_host(index: 0, counters: counters));
    await tester.pumpWidget(_host(index: 1, counters: counters));
    await tester.pumpWidget(_host(index: 2, counters: counters));
    final initBefore = [for (final c in counters) _of(c, 'init')];
    final buildBefore = [for (final c in counters) _of(c, 'build')];

    // 同 index=2 再 pump：child 全是新实例（模拟 _tabsRevision 整树重建）。
    await tester.pumpWidget(_host(index: 2, counters: counters));

    // 已建记录不丢：不重跑 initState（页面不重新发请求/不重挂监听），
    // 保活内容仍在树里。
    for (var i = 0; i < 3; i++) {
      expect(_of(counters[i], 'init'), initBefore[i],
          reason: 'tab$i 已建且未超上限，父级重建不应重建其 State');
      expect(_built('tab$i'), findsOneWidget);
    }
    // Element 树还在（widget 配置换新触发 rebuild，State 原样复用）。
    expect(_of(counters[1], 'build'), greaterThan(buildBefore[1]));

    // 访问序不丢：重建后切到 3，被淘汰的仍是最旧的 tab0。
    await tester.pumpWidget(_host(index: 3, counters: counters));
    expect(_built('tab0'), findsNothing);
    expect(_of(counters[0], 'dispose'), 1);
    expect(_built('tab1'), findsOneWidget);
    expect(_built('tab2'), findsOneWidget);
  });
}
