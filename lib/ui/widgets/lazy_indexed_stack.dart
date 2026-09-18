import 'package:flutter/material.dart';

/// 只在首次被选中时才构建对应 child 的 [IndexedStack]，带 LRU 保活上限。
///
/// 普通 IndexedStack 会一次性构建全部 children，导致所有页面
/// 都在 initState 中发起网络请求。这里通过懒构建
/// 保证只有被访问过的 tab 才会真正初始化，避免重复请求与重复监听。
///
/// 保活不是无限期的：已建 child 数超过 [maxKeepAlive]（默认
/// [LazyIndexedStack.defaultMaxKeepAlive]）时，按 LRU 淘汰最久未访问的
/// ——其子树整体从树中移除，Element/State 被回收。这是「只收内存、
/// 不丢状态」的契约：
/// - 数据：页面走各自的磁盘缓存（SWR：磁盘命中直接上屏 + 后台静默刷新），
///   重进被淘汰的 tab 不出现网络白屏；
/// - 滚动位置：页面级 PageStorageKey 的 bucket 挂在 route 层，页面
///   dispose 后重建仍可恢复。
///
/// [LazyIndexedStack.defaultMaxKeepAlive] 对 2 个 children 的形态
/// （移动端 首页/我的）天然无影响——不足上限永不淘汰。
class LazyIndexedStack extends StatefulWidget {
  const LazyIndexedStack({
    super.key,
    required this.index,
    required this.children,
    this.maxKeepAlive = defaultMaxKeepAlive,
  });

  /// 默认保活上限：desktop_shell 4 个分区最多保 3 个已建子树。
  static const int defaultMaxKeepAlive = 3;

  /// 当前显示的 child 下标。
  final int index;

  /// 全部 children（未建的槽位渲染 [SizedBox.shrink] 占位）。
  final List<Widget> children;

  /// 最多同时保活的已建 child 数；超出时按 LRU 淘汰最久未访问者，
  /// 当前显示的 [index] 永不淘汰。
  final int maxKeepAlive;

  @override
  State<LazyIndexedStack> createState() => _LazyIndexedStackState();
}

class _LazyIndexedStackState extends State<LazyIndexedStack> {
  /// 已构建的 child 下标，保序即访问序：集合字面量运行时为 LinkedHashSet，
  /// 插入有序——越靠后越近访问，首位即 LRU 淘汰候选。父级重建
  /// （didUpdateWidget）只更新访问序，从不清空记录。
  final _built = <int>{};

  /// 记一次访问：若为新下标则触发懒构建，已有则提到最新；随后按上限
  /// 淘汰。只在 initState / didUpdateWidget 中调用（重建已排程，无需
  /// 再 setState）。
  void _touch(int index) {
    _built
      ..remove(index) // 已存在时移除再追加 = 提为最新
      ..add(index);
    // 上限兜底至少 1：无论如何都要保住当前显示的 child。
    var limit = widget.maxKeepAlive;
    if (limit < 1) limit = 1;
    while (_built.length > limit) {
      final oldest = _built.first;
      // 当前显示 index 永不淘汰（防御：正常时序下它刚被提为最新，
      // 不可能是首位）。
      if (oldest == widget.index) break;
      _built.remove(oldest); // 对应槽位回到 SizedBox.shrink，子树整体卸载
    }
  }

  @override
  void initState() {
    super.initState();
    _touch(widget.index);
  }

  @override
  void didUpdateWidget(covariant LazyIndexedStack oldWidget) {
    super.didUpdateWidget(oldWidget);
    // children 数量变化（如形态切换）时剔除越界下标，防残留失真。
    _built.removeWhere((i) => i >= widget.children.length);
    // 只更新访问序，绝不清空已建记录：desktop_shell 的 _tabsRevision
    // 会经 ValueListenableBuilder 整树重建到这里，已访问分区必须原样保活。
    _touch(widget.index);
  }

  @override
  Widget build(BuildContext context) {
    return IndexedStack(
      index: widget.index,
      children: [
        for (var i = 0; i < widget.children.length; i++)
          _built.contains(i) ? widget.children[i] : const SizedBox.shrink(),
      ],
    );
  }
}
