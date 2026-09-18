import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/cache_service.dart';
import '../../services/network_monitor.dart';

/// 内容区块的「缓存 + SWR（stale-while-revalidate）」状态基类。
///
/// 统一首页三个内容区块（推荐 / 排行榜 / 电台）此前各自手写的生命周期骨架：
/// - 冷启动单 flight：内存缓存 → 磁盘缓存 → 网络（命中前两级不重复请求）；
/// - 磁盘命中先上屏，后台静默刷新；失败/空结果保持缓存，不闪错误页；
/// - 手动刷新（[refresh]）：自增代数作废在途响应，驱动横轨回位与均衡器动画；
/// - 断网进入停留在缓存/错误页，网络恢复后自动静默刷新；
/// - 代数（epoch）防倒灌：旧代数晚到的响应不写缓存、不覆盖 UI。
///
/// 页面只实现数据钩子：
/// - [fetchData]：组合请求、图片合并、分部容错都装在这里；
/// - [decodeCache]/[encodeCache]/[hasContent]/[cacheKey]/[cacheTtl]：持久化契约；
/// - [cachedData]：静态内存缓存存取（Dart 泛型基类无法声明静态成员）。
///
/// 主数据之外的附加数据（如排行榜的新歌推荐，独立缓存 key、独立 Future）走
/// [restoreSidecarFromDisk] / [onSectionRestored] / [loadSidecar] 三个钩子，
/// 由页面自管；推荐页 / 电台页无附加数据，使用默认空实现即可。
///
/// 空结果的统一语义：不写缓存、不覆盖内存缓存；静默刷新拿到空响应视同失败
/// （保持旧数据上屏），手动刷新拿到空响应如实展示空态（用户主动动作）。
abstract class SwrSectionState<W extends StatefulWidget, T> extends State<W> {
  // ---------------- 子类必须实现的数据钩子 ----------------

  CacheService get cache;

  /// 静态内存缓存（进程内跨页面保活，如首页 tab 切换不重拉）。
  T? get cachedData;
  set cachedData(T? value);

  String get cacheKey;
  Duration get cacheTtl;

  T decodeCache(Map<String, dynamic> json);
  Map<String, dynamic> encodeCache(T data);

  /// 是否有实际内容：全空说明多半是接口异常的静默空数据。
  bool hasContent(T data);

  /// 拉取主数据。
  Future<T> fetchData();

  // ---------------- 子类可选覆写的行为钩子 ----------------

  /// 网络加载是否就绪。返回 false 时冷启动无缓存也不发请求（保持骨架，
  /// 等就绪后由页面调 [loadIfNeverLoaded]）。默认 true。
  bool get readyToFetch => true;

  /// 主数据每次落地（内存/磁盘恢复或网络刷新完成）后回调，如推荐页的
  /// 自动播放恢复。可能被多次调用，实现需自带幂等。
  void onDataArrived(T data) {}

  /// 手动刷新开始时回调（此时 [railResetEpoch] 已自增）。
  void onManualRefreshStart() {}

  /// 冷启动磁盘恢复阶段与主数据并发调用一次：恢复附加数据的磁盘缓存。
  Future<void> restoreSidecarFromDisk() async {}

  /// 主数据命中缓存（内存或磁盘）上屏后调用：恢复附加数据的展示态。
  void onSectionRestored() {}

  /// 每个网络刷新周期（冷启动直连 / 静默刷新 / 手动刷新）开始时与主数据
  /// 并发调用：加载附加数据。异常由基类吞掉，不影响主数据。
  Future<void>? loadSidecar(int epoch) => null;

  // ---------------- 基类持有的骨架状态 ----------------

  Future<T>? _future;
  int _loadEpoch = 0;
  bool _silentRefreshing = false;
  bool _manualRefreshing = false;
  int _railResetEpoch = 0;
  StreamSubscription<void>? _networkRestoredSub;

  /// 主数据 Future；null 表示磁盘恢复中或等待就绪（页面显示骨架）。
  @protected
  Future<T>? get sectionFuture => _future;

  /// 顶部均衡器刷新动画的可见性（静默或手动刷新在途）。
  @protected
  bool get showRefreshEqualizer => _silentRefreshing || _manualRefreshing;

  /// 横轨重置代数：手动刷新自增，页面用它做 ValueKey 重建横轨回最左。
  @protected
  int get railResetEpoch => _railResetEpoch;

  /// 当前加载代数（附加数据写缓存守卫用，见 [loadSidecar]）。
  @protected
  int get currentEpoch => _loadEpoch;

  @override
  void initState() {
    super.initState();
    final cached = cachedData;
    if (cached != null) {
      _future = Future.value(cached);
      onDataArrived(cached);
      onSectionRestored();
      _silentRefresh();
    } else {
      _initFromDiskOrNetwork();
    }
    // 断网进入会停留在错误/缓存页上，恢复网络后自动刷新。
    _networkRestoredSub = NetworkMonitor.instance.onConnectivityRestored
        .listen((_) => _silentRefresh());
  }

  @override
  void dispose() {
    _networkRestoredSub?.cancel();
    super.dispose();
  }

  /// 冷启动单 flight：先读磁盘，命中则显示缓存 + 静默刷新，未命中才走网络。
  Future<void> _initFromDiskOrNetwork() async {
    final epoch = ++_loadEpoch;
    // 附加数据的磁盘读取与主数据并发，尽早启动。
    final sidecarFuture = restoreSidecarFromDisk();
    try {
      final result = await cache.read<T>(
        cacheKey,
        decode: decodeCache,
        ttl: cacheTtl,
      );
      // 磁盘读取期间用户已手动刷新（epoch 变化）：让位，不再回写缓存态。
      if (!mounted || epoch != _loadEpoch) return;
      if (result != null) {
        try {
          final data = result.data;
          if (hasContent(data)) {
            await _adoptRestoredData(data, sidecarFuture, epoch);
            return;
          }
        } catch (_) {
          // 缓存损坏则继续走网络。
        }
      }
    } catch (_) {
      // 磁盘读取失败则继续走网络。
    }
    if (!mounted || epoch != _loadEpoch) return;
    try {
      await sidecarFuture;
    } catch (_) {}
    if (!mounted || epoch != _loadEpoch) return;
    if (!readyToFetch) return;
    _startNetworkLoad(epoch);
  }

  /// 缓存数据上屏（内存 / 磁盘恢复共用）。
  Future<void> _adoptRestoredData(
    T data,
    Future<void> sidecarFuture,
    int epoch,
  ) async {
    cachedData = data;
    try {
      await sidecarFuture;
    } catch (_) {}
    // 等待附加数据期间用户已手动刷新（epoch 变化）：旧缓存不能覆盖新响应。
    if (!mounted || epoch != _loadEpoch) return;
    setState(() {
      _future = Future.value(data);
    });
    onSectionRestored();
    onDataArrived(data);
    _silentRefresh();
  }

  /// 冷启动直连网络（磁盘未命中或缓存损坏）。
  void _startNetworkLoad(int epoch) {
    final future = fetchData();
    _future = future;
    unawaited(_runSidecar(loadSidecar(epoch)));
    // 契约：此处刻意不加 mounted 守卫（仅 epoch 守卫）——dispose 后仍允许
    // 在途请求落地写内存/磁盘缓存（LazyIndexedStack LRU 淘汰重进后秒显）；
    // 因此 onDataArrived 实现方必须自行 mounted 守卫。
    unawaited(future.then((data) {
      if (epoch == _loadEpoch && hasContent(data)) {
        cachedData = data;
        unawaited(_persist(data));
        onDataArrived(data);
      }
    }).catchError((Object _) {}));
    setState(() {});
  }

  /// 后台静默刷新：成功更新 UI 与缓存，失败/空结果保持缓存不变。
  Future<void> _silentRefresh() async {
    if (_silentRefreshing) return;
    // 冷启动仍在磁盘恢复窗口（无 future、无内存缓存）时让位给
    // _initFromDiskOrNetwork：此时抢跑会自增代数作废 init 的恢复结果，
    // 而 fetch 失败后 _future 仍是 null——页面停在无错误态、无重试的
    // 骨架上，成为死胡同（只能等下一次网络事件/登录态变化解锁）。
    if (_future == null && cachedData == null) return;
    final epoch = ++_loadEpoch;
    _silentRefreshing = true;
    // 触发一次重建，让顶部均衡器动画即时出现。
    if (mounted) setState(() {});
    try {
      final sidecarFuture = loadSidecar(epoch);
      final data = await fetchData();
      // 等待期间用户已手动刷新（epoch 变化）：丢弃本响应，避免旧数据倒灌。
      if (!mounted || epoch != _loadEpoch) return;
      if (!hasContent(data)) return;
      cachedData = data;
      unawaited(_persist(data));
      setState(() {
        _future = Future.value(data);
      });
      onDataArrived(data);
      // 附加数据落地后再收均衡器动画（保持原先「整周期一条动画」语义）。
      await _runSidecar(sidecarFuture);
    } catch (_) {
      // 静默刷新失败，保持缓存数据不变
    } finally {
      _silentRefreshing = false;
      // 收起顶部均衡器动画（正常路径已有 setState 更新数据，这里兜底早退分支）。
      if (mounted) setState(() {});
    }
  }

  /// 手动刷新起跑前先让均衡器展开的时间：[RefreshEqualizer] 的高度过渡
  /// 第一帧从 0 开始（AnimatedSize 裁剪子内容），横轨换 Key 整轨重建、
  /// 发请求等重活若叠在首帧会把帧率打没，动画要等刷新结束才可见。
  /// 延后约 100ms（easeOutCubic 下已展开 ~78%）再上重活，保证用户
  /// 先看到「正在刷新」的反馈。
  static const _refreshWarmup = Duration(milliseconds: 100);

  /// 对外入口：手动刷新（双击首页 / 桌面刷新按钮 / 下拉刷新 / 错误重试）。
  ///
  /// 双击刷新优先级最高：自增代数使在途的静默刷新/冷启动恢复响应作废。
  /// 已在手动刷新中则忽略后续点按：否则首次完成会把 [_manualRefreshing]
  /// 清掉，第二次仍在途时均衡器动画会提前收起（数据安全由代数保证，
  /// 不受此影响）。
  Future<void> refresh() async {
    if (_manualRefreshing) {
      return;
    }
    final epoch = ++_loadEpoch;
    _manualRefreshing = true;
    // 先只翻刷新态重建（轻帧）：顶部均衡器当帧出现。等展开过渡明显
    // 可见后再启动重活，见 [_refreshWarmup]。
    setState(() {});
    await Future<void>.delayed(_refreshWarmup);
    if (!mounted) return;
    if (epoch != _loadEpoch) {
      // 预热期间代数被并发刷新（网络恢复触发的静默刷新等）抢占：本次
      // 手动刷新作废，收起均衡器退出。
      setState(() => _manualRefreshing = false);
      return;
    }
    // 横轨回到最左侧：页面用 railResetEpoch 做 ValueKey 重建横轨。
    _railResetEpoch++;
    onManualRefreshStart();
    final sidecarFuture = loadSidecar(epoch);
    final future = fetchData();
    _future = future;
    setState(() {});
    try {
      final data = await future;
      // 与 _silentRefresh 对齐：手动刷新拿到的新数据同样落地内存/磁盘缓存，
      // 否则刷新后离线重启会退回刷新前的旧缓存（旧版 _loadRanks 语义）。
      if (mounted && epoch == _loadEpoch && hasContent(data)) {
        cachedData = data;
        unawaited(_persist(data));
        onDataArrived(data);
      }
    } catch (_) {}
    await _runSidecar(sidecarFuture);
    if (!mounted) return;
    setState(() => _manualRefreshing = false);
  }

  /// 就绪后补跑一次网络加载（如推荐页 auth 恢复完成时）；已有数据则忽略。
  @protected
  void loadIfNeverLoaded() {
    if (!mounted || _future != null) return;
    _startNetworkLoad(++_loadEpoch);
  }

  Future<void> _persist(T data) async {
    try {
      await cache.write(cacheKey, encodeCache(data));
    } catch (_) {
      // 缓存写入失败不影响已拿到的网络数据上屏。
    }
  }

  /// 附加数据异常只吞不抛：绝不影响主数据流程。
  Future<void> _runSidecar(Future<void>? sidecar) async {
    if (sidecar == null) return;
    try {
      await sidecar;
    } catch (_) {}
  }
}
