// Windows 桌面歌词主窗侧桥接。
//
// 职责：把 DesktopLyricsService 门面 API 一比一映射到 desktop_multi_window
// 悬浮窗（lib/ui/desktop/lyrics_overlay_window.dart）。Windows/Linux 桌面
// 共用（门控见 DesktopLyricsService._isDesktopBridge，DWM 拉伸规避等注释
// 以 Windows 为主）；Android 路径不经此类。
//
// 消息协议（与悬浮窗侧约定一致）：
// - main -> sub：updateLyric {current, next, isPlaying, activeOnBottom} /
//   updateSettings {DesktopLyricsSettings.toMap()} /
//   updateProgress {progress, isPlaying} /
//   updatePlayState {isPlaying}（仅播放态，不触发换句重置进度）
//   （不向子窗发 close：主窗侧关闭直接走原生 window.close）。
// - sub -> main：windowClosed {}（用户手动关闭，触发可见性回调与就绪门控复位）/
//   overlayReady {}（子引擎通道就绪：主窗先打开就绪门控，再补发缓存的歌词、
//   设置与进度；门控打开前所有主->子推送静默跳过，避免子引擎 handler 注册完成前
//   invoke 必抛的 MissingPluginException 竞态）/
//   controlPlayback (action: 'previous' | 'togglePlay' | 'next')（悬停播控条触发主窗播控）/
//   setLyricsLocked (locked: bool)（子窗工具栏请求切换锁定：主窗侧统一落盘、
//   通知设置页，并把新 settings 回推子窗，子窗不本地直改锁定状态）/
//   updateOverlaySettings (DesktopLyricsSettings.toMap())（子窗请求更新设置）/
//   openLyricsSettings {}（子窗请求打开设置页）。
//
// API 名以包源码为准（desktop_multi_window 0.2.1）：
// - DesktopMultiWindow.createWindow([arguments]) -> WindowController
//   （子引擎以 args=['multi_window', id, arguments] 重新执行 main()）
// - DesktopMultiWindow.invokeMethod(targetWindowId, method, [arguments])
//   （主窗 id 固定为 0，无 sendToMain/sendToWindow API）
// - DesktopMultiWindow.setMethodHandler(handler(call, fromWindowId))
import 'dart:async';
import 'dart:convert';
// window_manager/desktop_multi_window 未重导出 dart:ui 类型。
import 'dart:math' as math;
import 'dart:ui' show Offset, Rect, Size;

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show MethodCall;
import 'package:screen_retriever/screen_retriever.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'desktop_lyrics_service.dart';

class WindowsDesktopLyricsBridge {
  WindowsDesktopLyricsBridge({
    DesktopLyricsVisibilityChanged? onVisibilityChanged,
    DesktopLyricsPlaybackAction? onPlaybackAction,
    DesktopLyricsLockChanged? onLockChanged,
    ValueChanged<DesktopLyricsSettings>? onSettingsChanged,
    VoidCallback? onOpenSettings,
  }) : _onVisibilityChanged = onVisibilityChanged,
       _onPlaybackAction = onPlaybackAction,
       _onLockChanged = onLockChanged,
       _onSettingsChanged = onSettingsChanged,
       _onOpenSettings = onOpenSettings;

  final DesktopLyricsVisibilityChanged? _onVisibilityChanged;
  final DesktopLyricsPlaybackAction? _onPlaybackAction;
  final DesktopLyricsLockChanged? _onLockChanged;
  final ValueChanged<DesktopLyricsSettings>? _onSettingsChanged;
  final VoidCallback? _onOpenSettings;

  /// 悬浮窗尺寸基准（与悬浮窗侧约定一致；主窗/子窗共用的唯一定义处）。
  ///
  /// 宽度恒定；高度自 v3.0.11 起同样恒定（[overlayFixedWindowHeight]，见
  /// 该常量注释），下列常量为**下限/单行**基准值，同时是位置语义迁移的
  /// 冻结锚点。窗口纵向分两带：[0, overlayMenuPanelHeight] 是**常驻菜单带**
  /// （平时透明且穿透，快捷菜单展开时菜单淡入于此），之下直到窗口底边是
  /// 卡片带（= 历史 124px 窗口的全部内容：工具栏/解锁胶囊专属带 + 歌词带，
  /// 底边对齐、随模式/字号在预分配空间内伸缩）。
  ///
  /// 历史版本窗口只有卡片带高度（124），快捷菜单展开/收起时原生
  /// setBounds 在 124↔296 间切换——Windows DWM 在 Flutter 新帧产出前会用
  /// 旧帧内容拉伸合成新尺寸（透明无框窗尤甚，Alacritty#7898 /
  /// framelesshelper#29 同源问题），即用户看到的"点设置歌词闪一下"。
  /// 现窗口常驻展开高度、菜单收展改为纯 Flutter 动画，从根上消除
  /// resize 中间帧；代价是上方菜单带平时必须穿透（见悬浮窗侧光标轮询），
  /// 否则会挡住下方应用的点击。
  static const double overlayWidth = 780;
  static const double lyricsTopInset = 36;
  static const double overlayLyricsHeight = 88;
  static const double overlayHeight = lyricsTopInset + overlayLyricsHeight;

  /// 快捷设置菜单面板高度：菜单带高度（历史 172；新增「歌词进度」行后
  /// 为 212 —— 菜单是整块常驻高度里浮出来的，行数变了这块必须跟着长）。
  static const double overlayMenuPanelHeight = 212;

  /// 窗口常驻总高度（菜单带 + 卡片带）。窗口不再随菜单收展改变尺寸。
  ///
  /// v3.0.11 起现行窗口恒为 [overlayFixedWindowHeight]（408，容纳最大
  /// 卡片）；本值 336 是 v3.0.10 及之前所有存量位置对应的窗口高度，仅
  /// 供位置语义迁移（四）换算（旧顶边 + 336 = 底边），不再用于建窗。
  static const double overlayWindowHeight =
      overlayHeight + overlayMenuPanelHeight;

  /// 歌词带/卡片随模式与字号在 **Flutter 层**伸缩（v3.0.11 起），但窗口
  /// 高度恒定：[overlayFixedWindowHeight] = 菜单带 212 + 最大卡片 196
  /// （工具栏 36 + 歌词带上限 160）。卡片贴窗口底、在预分配的透明空间内
  /// 向上伸缩，原生窗口**永不因设置变化 resize** —— 透明无框窗原生
  /// resize 时 DWM 会用旧帧拉伸合成新尺寸（Alacritty#7898 同源），历史
  /// 上"菜单收展原生 124↔296 切换"因此闪帧，收展改纯 Flutter 动画后才
  /// 消除；字号动态高度若走原生 resize 会原样复发（步进连点一卡一卡）。
  ///
  /// 歌词带高度函数族（单行恒 88；双行 = fontSize×1.4×(1+stagger)+8，
  /// 钳 [88,160]）只约束 Flutter 布局，与原生窗口尺寸解耦。默认字号 24
  /// 落钳制下限 88 —— 存量用户默认观感零变化；字号调大歌词带在窗口内
  /// 长高、多出的窗口空间透明且穿透（菜单收起态）。
  static const double dualLineStaggerFactor = 0.9;
  static const double lyricsLineHeightFactor = 1.4;
  static const double maxOverlayLyricsHeight = 160;

  /// 歌词带高度（逻辑 px）：单行恒 [overlayLyricsHeight]；双行 =
  /// 上行 + 下行（×[dualLineStaggerFactor]）两行行高 + 行距 4 + 呼吸 4
  /// （公式合计 +8），钳制 [overlayLyricsHeight, maxOverlayLyricsHeight]。
  static double overlayLyricsHeightFor(DesktopLyricsSettings settings) {
    if (settings.singleLine) return overlayLyricsHeight;
    final h =
        settings.fontSize *
            lyricsLineHeightFactor *
            (1 + dualLineStaggerFactor) +
        8.0;
    return h.clamp(overlayLyricsHeight, maxOverlayLyricsHeight);
  }

  /// 卡片带高度（工具栏带 + 歌词带）。
  static double overlayHeightFor(DesktopLyricsSettings settings) =>
      lyricsTopInset + overlayLyricsHeightFor(settings);

  /// 窗口常驻总高度（菜单带 + 最大卡片带）。设置变化只在 Flutter 层
  /// 重排，原生窗口高度恒为此值。
  static const double overlayFixedWindowHeight =
      overlayMenuPanelHeight + lyricsTopInset + maxOverlayLyricsHeight;

  /// screenRetriever 不可用（异常/插件未注册）时的降级停靠原点（**底边
  /// 左角**语义）：经 [overlayFrameForBottomOrigin] 换算后窗口应完整落在
  /// 虚拟屏 (100, 100) 内侧，与历史顶边语义时代的固定位置 (100,100) 同款
  /// 落点。此值同时充当 [clampOverlayOriginToVisibleAreas] 在无显示器信息
  /// 时的 [fallback]：若误用顶边语义，窗口会大半移出屏外，且（有存量
  /// 位置时）prefs 会被回写成同款坏值。
  static const Offset overlayDegradedFallbackOrigin =
      Offset(100, 100 + overlayFixedWindowHeight);

  /// 悬浮窗拖动位置的持久化键（子窗 window_manager 逻辑坐标；主窗侧
  /// 迁移+钳制后回写，子窗启动时读取恢复）。
  ///
  /// 存值恒为**现行窗口语义**：歌词带动态化之前是「窗口顶边」（含常驻
  /// 菜单带），之后改为**窗口底边**（= 卡片底边；窗口高度现已恒定，底边
  /// 语义保留是对窗口高度未来演进——如菜单带再加行——的免疫）——由
  /// 下面的一次性迁移键标记，见
  /// [markOverlayPositionSemanticsCurrent] 的写入职责。
  static const String windowLeftPrefKey = 'desktop_lyrics.window.left';
  static const String windowTopPrefKey = 'desktop_lyrics.window.top';

  /// 窗口底边语义的持久化键（迁移（四）起启用，旧 top 键停写保留供迁移
  /// 换算）。已知取舍：用户降级回旧版移动窗口后再升级，旧版只写 top 键，
  /// 本仓仍优先读底边键，位置会回退到降级前——换取正向升级路径的稳定。
  static const String windowBottomLeftPrefKey =
      'desktop_lyrics.window.bottom.left';
  static const String windowBottomYPrefKey = 'desktop_lyrics.window.bottom.y';

  /// 位置语义迁移标记（下面三枚一次性开关）：三者为 true 表示 prefs 里的
  /// [windowTopPrefKey] 已是**现行窗口语义**，无需再迁移。
  ///
  /// 写入职责（唯一契约，见 [markOverlayPositionSemanticsCurrent]）：凡是把
  /// 现行语义坐标写进 prefs 的路径，都必须在同一次落盘里置位这三枚键——
  /// 主窗 [loadStoredOverlayOrigin] 完成存量迁移/钳制之后，以及子窗落盘
  /// **活窗口坐标**时。漏置一次，下次启动就会把这个坐标当成迁移前旧值再减
  /// 一遍；多置一次是幂等的。
  ///
  /// 位置语义迁移（一）：124 高度之前，窗口顶边 == 歌词带顶边；
  /// 现在窗口顶边之上多了 [lyricsTopInset] 的工具栏带，存量位置必须
  /// 一次性减去该偏移，否则升级后歌词整体下沉 36px。
  static const String windowInsetMigratedPrefKey =
      'desktop_lyrics.window.inset_migrated';

  /// 位置语义迁移标记（二）：常驻高度改造之前，记忆的 top 是 124 高
  /// 卡片带窗口的顶边；现在窗口顶边之上多了常驻菜单带，存量位置必须
  /// 一次性减去 [overlayMenuPanelHeight]，否则升级后歌词整体下沉
  /// 172px。迁移由 [loadStoredOverlayOrigin] 在 createWindow 之前落盘——
  /// 子窗启动时直接读 prefs。
  static const String windowTallMigratedPrefKey =
      'desktop_lyrics.window.tall_migrated';

  /// 位置语义迁移标记（三）：「歌词进度」行把菜单带从 172 撑到 212 时，
  /// [windowTallMigratedPrefKey] 已对 v3.0.7 存量位置置位、不会再补偿。
  /// 这批位置需再减去差值（212-172），否则升级后歌词整体下沉 40px。
  /// 判定必须用“本次启动前”的旧键值：新用户首次落盘会在同一次启动里
  /// 先走迁移（二)（已按现行高度全额补偿），不能再补减。
  static const String windowMenuProgressRowMigratedPrefKey =
      'desktop_lyrics.window.menu_progress_row_migrated';

  /// 「歌词进度」行加入前的菜单带高度（[overlayMenuPanelHeight] 的旧值，
  /// 仅迁移（三）计算差值用）。
  static const double overlayMenuPanelHeightBeforeProgressRow = 172;

  /// 位置语义迁移（四）：v3.0.10 及之前窗口恒为 [overlayWindowHeight]
  /// （336）高、记忆窗口顶边；现行窗口恒为 [overlayFixedWindowHeight]、
  /// 改存**窗口底边**（= 卡片底边，卡片屏幕位置的自然锚点）。存量顶边
  /// 一次性加 336 换算为底边（冻结高度即迁移当时的 [overlayWindowHeight]）。
  ///
  /// 迁移（四）一次性开关：为 true 表示 prefs 已有 [windowBottomYPrefKey]
  /// 底边坐标（由本函数迁移写入或子窗落盘的活坐标），旧 top 键不再读取。
  static const String windowBottomMigratedPrefKey =
      'desktop_lyrics.window.bottom_migrated';

  /// 钳制时至少保留的可见像素（与主窗 kMinVisibleEdge 语义一致）。
  static const double _kMinVisibleEdge = 80;

  WindowController? _window;
  bool _handlerRegistered = false;
  bool _visible = false;

  /// 子窗消息通道就绪门控：子引擎完成样式/位置设置并注册消息 handler 后
  /// 才会上报 overlayReady（见 lyrics_overlay_window.dart）。在此之前对子窗
  /// 的任何 invokeMethod 都抛 MissingPluginException，故推送路径在此期间
  /// 只更新缓存、不真正 invoke，待 overlayReady 握手后统一补发。
  bool _overlayReady = false;

  // 最近一次推送的内容：悬浮窗引擎启动存在窗口期，重show/补发时以缓存为准。
  DesktopLyricsSettings _settings = const DesktopLyricsSettings();
  String _current = '';
  String _next = '';
  bool _isPlaying = false;
  double _progress = 0.0;
  bool _appForeground = true;

  // ---- updateProgress 节流状态 ----
  // 主窗存在两条进度推送路径（positionStream tick + 播放中的持久帧回调，
  // 帧回调频率 = 主窗刷新率，可高达 165Hz），子窗每条消息都会全量重建并
  // 重绘歌词层。在桥接层统一节流：距上次发送 ≥33ms 且进度增量超过
  // [_kProgressSendEpsilon]（或播放态翻转）才真正 invoke，否则只更新缓存。
  DateTime _lastProgressSentAt = DateTime.fromMillisecondsSinceEpoch(0);
  double _lastSentProgress = -1.0;
  bool _lastSentIsPlaying = false;
  static const Duration _kProgressMinSendInterval = Duration(milliseconds: 33);
  static const double _kProgressSendEpsilon = 1 / 256;

  /// 双行交替高亮：当前句是否落在**下行**（= 歌词行下标为奇数）。
  /// 子窗据此决定哪个字行带动画进度：正在唱的那一行文字不移动，
  /// 只让另一行换成下一句（见 buildOverlayLyricsBody）。
  bool _activeOnBottom = false;

  /// 悬浮窗是否可见（内部状态，不依赖平台查询）。
  bool get isVisible => _visible;

  /// 最近一次记录的前台状态（诊断/调试用途）。
  bool get appForeground => _appForeground;

  /// show/hide 串行化队列：开关连点时 createWindow/close 都是异步多步，
  /// 并发执行会造出幽灵窗口（hide 关了空引用，show 后续又把窗建出来；
  /// 两个 show 并发则第二个覆盖 _window，第一个成孤儿只能点卡片 X 关）。
  /// 所有创建/销毁走同一队列，顺序执行，终态必与最后一次操作一致。
  Future<void> _serial = Future.value();

  Future<T> _enqueue<T>(Future<T> Function() task) {
    final next = _serial.then((_) => task());
    _serial = next.then((_) {}, onError: (_) {});
    return next;
  }

  Future<bool> show({required String title, required String artist}) =>
      _enqueue(() => _showInner(title: title, artist: artist));

  Future<void> hide() => _enqueue(_hideInner);

  Future<bool> _showInner({
    required String title,
    required String artist,
  }) async {
    if (_visible && _window != null) {
      // 已在展示：复用旧窗，仅补发缓存内容（标题/歌手 v1 不上屏）。
      // 此处不得重置 _overlayReady：复用路径里子引擎不会重新上报
      // overlayReady，误重置会导致歌词停止刷新；若子引擎仍在启动窗口期，
      // _pushLyric 的门控会静默跳过，由随后的 overlayReady 握手补发。
      await _pushLyric();
      return true;
    }
    try {
      // 重建子窗：复位就绪门控，新引擎必须等待新一轮 overlayReady 握手
      // （上一窗口的就绪状态对新建引擎无效）。
      _overlayReady = false;
      // 懒注册主窗侧消息处理（先于子窗可能的 windowClosed 上报）。
      _ensureMethodHandler();
      // 初始 frame 必须先于 createWindow 算好：_initialFrame 会读取存量位置、
      // 做一次性语义迁移并回写 prefs，而子窗启动时直接读 prefs 恢复位置。
      // 反过来（先建窗后迁移）子窗有机会读到迁移前的旧语义坐标，并把那个
      // 坐标当"活坐标"再落盘，旧语义就被永久焊死。
      final initialFrame = await _initialFrame();
      final window = await DesktopMultiWindow.createWindow(
        jsonEncode(<String, dynamic>{
          'settings': _settings.toMap(),
          'current': _current,
          'next': _next,
          'isPlaying': _isPlaying,
          'activeOnBottom': _activeOnBottom,
          'title': title,
          'artist': artist,
        }),
      );
      try {
        // 子引擎就绪需数百毫秒，且悬浮窗入口在完成无标题栏样式/尺寸/位置
        // 恢复后会自行 show()（见 lyrics_overlay_window.dart 入口末尾）。
        // 主窗侧不得提前 show()，否则会闪现白底带标题栏的默认 720x120 窗口；
        // 此处预置初始位置：记忆位置（已主窗侧迁移+钳制）或底部居中默认值，
        // 后续由悬浮窗自行 setPosition 覆盖为记忆位置（逻辑坐标）。
        await window.setFrame(initialFrame);
      } on Exception catch (e) {
        debugPrint('[桌面歌词主窗] setFrame 失败: $e，关闭已创建窗口');
        // 布局/显示阶段失败：先关闭已创建的原生窗口，避免控制器被丢弃后
        // 原生窗口游离残留；再按创建失败路径统一处理。
        try {
          await window.close();
        } on Exception {
          // 窗口可能已被销毁。
        }
        rethrow;
      }
      _window = window;
      _visible = true;
      return true;
    } on Exception catch (e) {
      debugPrint('[桌面歌词主窗] show 失败: $e');
      _visible = false;
      _window = null;
      return false;
    }
  }

  Future<void> _hideInner() async {
    final window = _window;
    _visible = false;
    _window = null;
    // 子窗随之销毁：就绪状态失效，重开需等待新引擎的 overlayReady 握手。
    _overlayReady = false;
    if (window == null) return;
    try {
      // 主窗发起的关闭直接走原生 close（WM_CLOSE -> 销毁子窗与子引擎），
      // 不向子窗发 close 消息，避免与销毁竞态产生多余的 windowClosed 上报。
      await window.close();
    } on Exception {
      // 窗口可能已被销毁。
    }
  }

  Future<void> updateLyrics({
    required String current,
    required String next,
    required bool activeOnBottom,
  }) async {
    _current = current;
    _next = next;
    _activeOnBottom = activeOnBottom;
    if (!_visible) return;
    await _pushLyric();
  }

  Future<void> updatePlayState({required bool isPlaying}) async {
    _isPlaying = isPlaying;
    if (!_visible) return;
    // 播放态变化走专用消息：复用 updateLyric 会触发子窗"换句重置进度"，
    // 每次暂停/缓冲都把当前句已唱的逐字高亮清零（且暂停期间没有
    // updateProgress 帧把它补回来，直到恢复播放）。
    if (!_overlayReady) return;
    try {
      await _invokeSub('updatePlayState', <String, dynamic>{
        'isPlaying': isPlaying,
      });
    } on Exception {
      // 子窗已退出：缓存待下次 show 重发。
    }
  }

  Future<void> updateSettings(DesktopLyricsSettings settings) async {
    _settings = settings;
    // 未就绪（子引擎启动窗口期）只更新缓存，由 overlayReady 握手后补发。
    if (!_visible || !_overlayReady) return;
    try {
      await _invokeSub('updateSettings', settings.toMap());
    } on Exception {
      // 子窗已退出：缓存待下次 show 重发。
    }
  }

  Future<void> updateKaraokeProgress({
    required double progress,
    required Duration? lineDuration,
    required bool isPlaying,
  }) async {
    _progress = progress;
    _isPlaying = isPlaying;
    if (!_visible || !_overlayReady) return;
    // 节流 + 增量去重：子窗高亮只随消息推进（自身不内插），1/256 行宽的
    // 步进在 780px 窗口约 3px，视觉上不可分辨；换句时 progress 从 ~1.0 跳回
    // 0.0、暂停/恢复时 isPlaying 翻转，均无条件放行。
    final now = DateTime.now();
    final progressDelta = (progress - _lastSentProgress).abs();
    final playStateFlipped = isPlaying != _lastSentIsPlaying;
    final isLineReset =
        _lastSentProgress > 0.5 && progress < 0.5 && !playStateFlipped;
    final intervalElapsed =
        now.difference(_lastProgressSentAt) >= _kProgressMinSendInterval;
    if (!playStateFlipped &&
        !isLineReset &&
        (!intervalElapsed || progressDelta < _kProgressSendEpsilon)) {
      return;
    }
    _lastProgressSentAt = now;
    _lastSentProgress = progress;
    _lastSentIsPlaying = isPlaying;
    try {
      await _invokeSub('updateProgress', <String, dynamic>{
        'progress': progress,
        'isPlaying': isPlaying,
      });
    } on Exception catch (e) {
      debugPrint('[桌面歌词主窗] updateProgress 推送失败: $e');
    }
  }

  /// 仅内部记录；可见性由 PlayerController 依自身前台状态调度 show/hide。
  Future<void> setAppForeground({required bool isForeground}) async {
    _appForeground = isForeground;
  }

  Future<void> _pushLyric() async {
    // 就绪门控：子引擎 handler 注册完成前不 invoke（缓存已是最新，
    // overlayReady 握手后会补发），从源头消除 MissingPluginException。
    if (!_overlayReady) return;
    try {
      await _invokeSub('updateLyric', <String, dynamic>{
        'current': _current,
        'next': _next,
        'isPlaying': _isPlaying,
        'activeOnBottom': _activeOnBottom,
      });
    } on Exception catch (e) {
      // 最后防线：握手后的意外竞态（如窗口恰在销毁）。缓存待下次补发。
      debugPrint('[桌面歌词主窗] updateLyric 未送达，已缓存待补发: $e');
    }
  }

  Future<dynamic> _invokeSub(String method, dynamic arguments) async {
    final window = _window;
    if (window == null) return null;
    return DesktopMultiWindow.invokeMethod(window.windowId, method, arguments);
  }

  void _ensureMethodHandler() {
    if (_handlerRegistered) return;
    _handlerRegistered = true;
    DesktopMultiWindow.setMethodHandler((
      MethodCall call,
      int fromWindowId,
    ) async {
      // 只信任当前子窗的消息：热重启等路径下可能存在桥接已失忆的旧子窗，
      // 旧窗迟到的 windowClosed 会把指向新窗的 _window 清空、_visible 清
      // 假，造成"新窗歌词冻结/开关状态错乱"。
      if (_window == null || fromWindowId != _window!.windowId) {
        return null;
      }
      if (call.method == 'windowClosed') {
        // 主窗自己发起的关闭（hide/退出收口）时 _visible 已为 false：
        // 子窗 preventClose 拦截后补报的 windowClosed 不是用户手动关闭，
        // 不得触发可见性回调（否则会把持久化开关错误翻转为关）。
        if (!_visible) return null;
        // 子窗销毁：就绪门控同步失效，重建/重开需等待新一轮握手。
        _overlayReady = false;
        _visible = false;
        _window = null;
        _onVisibilityChanged?.call(visible: false, userClosed: true);
      } else if (call.method == 'overlayReady') {
        // 子引擎通道就绪：先打开就绪门控（本次补发自身也走门控路径），
        // 再补发启动窗口期内可能丢失的歌词与设置。
        _overlayReady = true;
        await _pushLyric();
        try {
          await _invokeSub('updateSettings', _settings.toMap());
        } on Exception catch (e) {
          debugPrint('[桌面歌词主窗] updateSettings 补发失败: $e');
        }
        try {
          await _invokeSub('updateProgress', <String, dynamic>{
            'progress': _progress,
            'isPlaying': _isPlaying,
          });
          // 握手补发已送达最新进度：同步节流基线，避免旧会话的
          // _lastSentProgress 抑制新窗口的首次增量推送。
          _lastProgressSentAt = DateTime.now();
          _lastSentProgress = _progress;
          _lastSentIsPlaying = _isPlaying;
        } on Exception catch (e) {
          debugPrint('[桌面歌词主窗] updateProgress 补发失败: $e');
        }
      } else if (call.method == 'controlPlayback') {
        final action = call.arguments?.toString();
        if (action != null && action.isNotEmpty) {
          _onPlaybackAction?.call(action);
        }
      } else if (call.method == 'setLyricsLocked') {
        // 子窗工具栏锁定按钮：不在子窗本地直改状态，由回调方（PlayerController）
        // 走 updateSettings 完成持久化 + 设置页通知，并经 updateSettings
        // 回推子窗后统一重建（锁定即全穿透）。
        _onLockChanged?.call(call.arguments == true);
      } else if (call.method == 'updateOverlaySettings') {
        final args = call.arguments;
        if (args is Map) {
          final newSettings = DesktopLyricsSettings.fromMap(
            args.cast<String, dynamic>(),
          );
          _onSettingsChanged?.call(newSettings);
        }
      } else if (call.method == 'openLyricsSettings') {
        _onOpenSettings?.call();
      }
      return null;
    });
  }

  /// 置位四枚一次性位置语义迁移键。
  ///
  /// 调用语义：**此刻 prefs 里的位置坐标已是现行窗口语义**（迁移（四）后
  /// 为 [windowBottomYPrefKey] 底边；此前为 [windowTopPrefKey] 顶边）。
  /// 只允许两类调用点：
  /// 1. 主窗 [loadStoredOverlayOrigin] 完成存量迁移/钳制之后（无存量坐标的
  ///    全新安装也要置位：此刻起 prefs 里不会再有旧语义坐标，之后由子窗落
  ///    盘的活坐标必为现行语义）；
  /// 2. 子窗落盘活窗口坐标时（lyrics_overlay_window.dart 的
  ///    persistOverlayWindowPosition）——活坐标按定义就是现行语义。
  ///
  /// 这个契约是位置相关 bug 的唯一根源：漏置一次，下次启动就把现行坐标当
  /// 迁移前旧值再减一遍（[lyricsTopInset] + [overlayMenuPanelHeight]，
  /// 历史上表现为整体上跳 248px）；多置是幂等的。
  static Future<void> markOverlayPositionSemanticsCurrent(
    SharedPreferences prefs,
  ) async {
    // 已置位就不再写盘：prefs 每次 set 都会整文件落盘，而稳态下（升级后
    // 的每一次拖动/关窗）这四枚键早已为 true，这里省掉无谓写盘。
    if (prefs.getBool(windowInsetMigratedPrefKey) != true) {
      await prefs.setBool(windowInsetMigratedPrefKey, true);
    }
    if (prefs.getBool(windowTallMigratedPrefKey) != true) {
      await prefs.setBool(windowTallMigratedPrefKey, true);
    }
    if (prefs.getBool(windowMenuProgressRowMigratedPrefKey) != true) {
      await prefs.setBool(windowMenuProgressRowMigratedPrefKey, true);
    }
    if (prefs.getBool(windowBottomMigratedPrefKey) != true) {
      await prefs.setBool(windowBottomMigratedPrefKey, true);
    }
  }

  /// 读取存量悬浮窗位置 → 一次性语义迁移 → 钳制可见区 → 回写 prefs
  /// （坐标 + 四枚语义键）。返回最终**逻辑底边左角**（窗口底边语义）；
  /// 无存量位置（全新安装）返回 null，由调用方落主屏默认落点。
  ///
  /// 记忆位置的主窗侧钳制不可省：悬浮窗侧（子引擎）只有 window_manager
  /// 可用（无 screen_retriever 插件注册），无法自行判断显示器配置变化，
  /// 不钳制的话拔掉副显示器后悬浮窗会恢复到屏幕外成为不可见的"僵尸窗"
  /// （锁定态全穿透，用户没有任何入口找回）。
  ///
  /// **必须先于 createWindow 调用**（见 [_showInner]）：子窗启动时直接读
  /// prefs 恢复位置，迁移晚于建窗会让子窗读到迁移前的旧语义坐标，之后它
  /// 落盘的"活坐标"就把旧语义永久焊死。
  ///
  /// [windowHeight] 为窗口完整逻辑高度（现行恒为 [overlayFixedWindowHeight]）：
  /// 钳制按窗口完整矩形判定，由调用方传入本会话实际建窗的高度——窗口
  /// 高度若再演进（如菜单带加行），随之传新值即自动兼容。
  @visibleForTesting
  static Future<Offset?> loadStoredOverlayOrigin({
    required List<Rect> visibleAreas,
    required Offset fallback,
    required double windowHeight,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final bottomLeft = prefs.getDouble(windowBottomLeftPrefKey);
      final bottomY = prefs.getDouble(windowBottomYPrefKey);
      if (bottomLeft != null && bottomY != null) {
        // 底边语义（迁移（四）后由本函数或子窗落盘写入）：直接钳制回写。
        final clamped = clampOverlayOriginToVisibleAreas(
          Offset(bottomLeft, bottomY),
          visibleAreas,
          fallback: fallback,
          windowHeight: windowHeight,
        );
        if (clamped.dx != bottomLeft || clamped.dy != bottomY) {
          await prefs.setDouble(windowBottomLeftPrefKey, clamped.dx);
          await prefs.setDouble(windowBottomYPrefKey, clamped.dy);
        }
        await markOverlayPositionSemanticsCurrent(prefs);
        return clamped;
      }
      final storedLeft = prefs.getDouble(windowLeftPrefKey);
      final storedTop = prefs.getDouble(windowTopPrefKey);
      if (storedLeft == null || storedTop == null) {
        // 全新安装：没有存量坐标要迁移，但语义键必须置位——本次会话随后由
        // 子窗落盘的活坐标是现行语义，不置位就会在第二次启动被误迁移。
        await markOverlayPositionSemanticsCurrent(prefs);
        return null;
      }
      // 一次性语义迁移（一）：88px 高时代窗口顶边 == 歌词带顶边；后来
      // 顶边之上多了 [lyricsTopInset] 的工具栏带，存量值需减去该偏移。
      var top = storedTop;
      if (!(prefs.getBool(windowInsetMigratedPrefKey) ?? false)) {
        top -= lyricsTopInset;
      }
      // 一次性语义迁移（二）：常驻高度改造前记忆的 top 是 124 高窗口
      // 顶边 == 卡片带顶边；现在顶边之上多了常驻菜单带，再减去
      // [overlayMenuPanelHeight] 保歌词屏幕位置不变。
      // tallMigratedBefore 供迁移（三）区分“老版本已迁移（172）”与
      // “本次启动刚迁移（现行高度）”，后者不得再补减。
      final tallMigratedBefore =
          prefs.getBool(windowTallMigratedPrefKey) ?? false;
      if (!tallMigratedBefore) {
        top -= overlayMenuPanelHeight;
      } else if (!(prefs.getBool(windowMenuProgressRowMigratedPrefKey) ??
          false)) {
        // 一次性语义迁移（三）：菜单带 172→212（新增「歌词进度」行）。
        // 老版本已走过迁移（二）的位置少减了 40px，这里补减差值；
        // 本次启动刚走迁移（二）的位置已按现行高度全额补偿，跳过。
        top -=
            overlayMenuPanelHeight - overlayMenuPanelHeightBeforeProgressRow;
      }
      // 一次性语义迁移（四）：336 高时代记忆的顶边 + 迁移当时的窗口高度 =
      // 窗口底边（卡片底边）。**必须落盘新键**：语义键在本路径置位
      // 后旧 top 键即冻结，若因"钳制前后一致"跳过写入，下次启动会读不到
      // 底边键、把旧 top 键再迁移一遍，位置每次启动 +336 漂移。
      final bottom = top + overlayWindowHeight;
      final clamped = clampOverlayOriginToVisibleAreas(
        Offset(storedLeft, bottom),
        visibleAreas,
        fallback: fallback,
        windowHeight: windowHeight,
      );
      await prefs.setDouble(windowBottomLeftPrefKey, clamped.dx);
      await prefs.setDouble(windowBottomYPrefKey, clamped.dy);
      await markOverlayPositionSemanticsCurrent(prefs);
      return clamped;
    } on Exception catch (e) {
      debugPrint('[桌面歌词主窗] 读取/钳制记忆位置失败，用默认位置: $e');
      return null;
    }
  }

  /// 悬浮窗初始 frame（物理像素，供 desktop_multi_window 的 setFrame）。
  ///
  /// 优先恢复记忆的拖动位置；无记忆时落主显示器底部居中。存量位置的读取/
  /// 语义迁移/钳制/回写全部由 [loadStoredOverlayOrigin] 承担，且必须先于
  /// createWindow 完成。记忆/默认位置统一为**底边左角**语义（对窗口高度
  /// 未来演进免疫的锚点），在此经 [overlayFrameForBottomOrigin] 换算顶边。
  Future<Rect> _initialFrame() async {
    var origin = overlayDegradedFallbackOrigin;
    var scaleFactor = 1.0;
    var visibleAreas = const <Rect>[];
    // 逻辑可见区 → 该屏缩放比：混合缩放多屏下，记忆位置落在副屏时必须按
    // 副屏缩放换算（此前恒用主屏缩放，副屏上会整体偏移）。
    var displayScales = const <({Rect area, double scale})>[];
    // 窗口高度恒定（容纳最大卡片）；设置变化只在 Flutter 层重排。
    const windowHeight = overlayFixedWindowHeight;
    try {
      final primary = await screenRetriever.getPrimaryDisplay();
      final all = await screenRetriever.getAllDisplays();
      final primaryArea = _visibleAreaOf(primary);
      visibleAreas = [
        primaryArea,
        for (final display in all)
          if (display.id != primary.id) _visibleAreaOf(display),
      ];
      displayScales = [
        for (final display in all)
          (
            area: _visibleAreaOf(display),
            scale: (display.scaleFactor ?? 1.0).toDouble(),
          ),
      ];
      scaleFactor = (primary.scaleFactor ?? 1.0).toDouble();
      // 默认停靠：窗口底边（= 卡片带底部）距主屏底边 80px（与历史版本
      // 一致；旧式顶边算法 top = bottom - overlayHeight - 80 - 菜单带，
      // 换算底边恰好同为 bottom - 80）。
      origin = Offset(
        primaryArea.left + (primaryArea.width - overlayWidth) / 2,
        primaryArea.top + primaryArea.height - 80,
      );
    } on Exception catch (e) {
      debugPrint('[桌面歌词主窗] 获取显示器信息失败，用固定位置: $e');
      // 拿不到显示器信息时无从钳制/换算，退回固定逻辑位置。
    }
    final storedOrigin = await loadStoredOverlayOrigin(
      visibleAreas: visibleAreas,
      fallback: origin,
      windowHeight: windowHeight,
    );
    if (storedOrigin != null) {
      origin = storedOrigin;
      scaleFactor =
          scaleForLogicalOrigin(displayScales, origin) ?? scaleFactor;
    }
    // 底边左角 → 顶边左角 + 物理像素换算（纯函数，供单测）。
    return overlayFrameForBottomOrigin(origin, scaleFactor: scaleFactor);
  }

  /// 取逻辑原点所在显示器的缩放比（纯函数，供单测）。
  ///
  /// 契约与 [clampOverlayOriginToVisibleAreas] 对齐：原点落在多个可见区的
  /// 交集（镜像/重叠）时取第一个；都不命中（跨屏缝隙等）返回 null，由调用
  /// 方回退主屏缩放。
  @visibleForTesting
  static double? scaleForLogicalOrigin(
    List<({Rect area, double scale})> displays,
    Offset origin,
  ) {
    if (displays.isEmpty) return null;
    for (final display in displays) {
      if (display.area.contains(origin)) return display.scale;
    }
    return null;
  }

  /// 底边左角原点 → 供 desktop_multi_window setFrame 的窗口 frame（物理
  /// 像素，纯函数，供单测）。
  ///
  /// desktop_multi_window 的 setFrame 底层是 MoveWindow（物理像素），而
  /// screen_retriever/window_manager 记忆位置都是逻辑坐标：必须按**窗口
  /// 最终落点所在显示器**的缩放（[scaleForLogicalOrigin]）换算。setFrame
  /// 吃窗口顶边，先按恒定窗口高度自底边反推顶边。
  @visibleForTesting
  static Rect overlayFrameForBottomOrigin(
    Offset origin, {
    required double scaleFactor,
  }) {
    final top = origin.dy - overlayFixedWindowHeight;
    return Offset(origin.dx * scaleFactor, top * scaleFactor) &
        Size(
          overlayWidth * scaleFactor,
          overlayFixedWindowHeight * scaleFactor,
        );
  }

  /// 显示器的可见区域：优先 visiblePosition/visibleSize，缺失时退回原点/整屏。
  static Rect _visibleAreaOf(Display display) {
    final position = display.visiblePosition ?? Offset.zero;
    final size = display.visibleSize ?? display.size;
    return Rect.fromLTWH(position.dx, position.dy, size.width, size.height);
  }

  /// 把悬浮窗**底边左角**钳制到至少留出 [_kMinVisibleEdge] 可见边（纯函数，
  /// 供单测）。
  ///
  /// 底边语义（= 卡片底边）：模式/字号引起的窗口高度变化都锚定这条边，
  /// 钳制判定的完整窗口矩形按 [windowHeight]（当前设置的窗口逻辑高度）
  /// 从底边反推顶边构建。与任一可见区域有足量交集 → 原样返回；否则钳入
  /// 第一个区域（右/下至少留 80px，窗口比区域宽时贴左/上）。无显示器
  /// 信息时返回 [fallback]。
  @visibleForTesting
  static Offset clampOverlayOriginToVisibleAreas(
    Offset origin,
    List<Rect> visibleAreas, {
    required Offset fallback,
    required double windowHeight,
  }) {
    if (visibleAreas.isEmpty) return fallback;
    // 钳制按常驻窗口（含菜单带）的完整矩形判定可见性；origin 是底边
    // 左角，顶边 = 底边 - 窗口高度。
    final windowRect = Rect.fromLTWH(
      origin.dx,
      origin.dy - windowHeight,
      overlayWidth,
      windowHeight,
    );
    for (final area in visibleAreas) {
      final intersection = area.intersect(windowRect);
      if (intersection.width >= _kMinVisibleEdge &&
          intersection.height >= _kMinVisibleEdge) {
        return origin;
      }
    }
    final area = visibleAreas.first;
    final clampedLeft = origin.dx
        .clamp(area.left, math.max(area.left, area.right - _kMinVisibleEdge))
        .toDouble();
    // 底边语义：窗口自底边向上延伸，底边钳入 [区域顶 + 80, 区域底 - 80]
    // 才保证至少 80px 窗口可见（旧顶边语义钳 [区域顶, 区域底 - 80]）。
    final clampedBottom = origin.dy
        .clamp(
          area.top + _kMinVisibleEdge,
          math.max(
            area.top + _kMinVisibleEdge,
            area.bottom - _kMinVisibleEdge,
          ),
        )
        .toDouble();
    return Offset(clampedLeft, clampedBottom);
  }
}
