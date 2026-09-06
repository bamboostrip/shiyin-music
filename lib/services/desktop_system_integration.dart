import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart'
    show Listenable, VoidCallback, debugPrint;
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:local_notifier/local_notifier.dart';
import 'package:window_manager/window_manager.dart';

import '../config/app_config.dart';

// =============================================================================
// 本文件聚合桌面形态（isDesktopFormFactor）的系统级集成：
// 下载完成通知 / 主窗标题 / 开机自启。
// 所有实现仅由桌面入口（main.dart / settings_page 桌面分组）构造与调用；
// 移动端/车机不构造任何实例，不触发任何平台通道。
// =============================================================================

/// 下载完成通知的标题（单曲与批量一致，正文区分）。
const String kDownloadNotificationTitle = '下载完成';

/// 主窗标题随播放的格式：'歌名 - 歌手 - 时音'，无播放回 '时音'。
///
/// 纯函数（供单测）；[DesktopWindowTitleBinder] 负责监听与设置。
String formatDesktopWindowTitle({
  String? songTitle,
  String? artist,
  String appName = AppConfig.appName,
}) {
  final title = (songTitle ?? '').trim();
  final artistName = (artist ?? '').trim();
  if (title.isEmpty) return appName;
  if (artistName.isEmpty) return '$title - $appName';
  return '$title - $artistName - $appName';
}

/// 单曲下载完成通知正文：'歌名 - 歌手'（缺歌手只给歌名，都缺给兜底文案）。
///
/// 纯函数（供单测）。
String singleDownloadNotificationBody({
  required String songTitle,
  required String artist,
}) {
  final title = songTitle.trim();
  final artistName = artist.trim();
  if (title.isEmpty && artistName.isEmpty) return '歌曲已保存到下载目录';
  if (title.isEmpty) return artistName;
  if (artistName.isEmpty) return title;
  return '$title - $artistName';
}

/// 批量下载完成通知正文：整个任务（含地址解析与文件传输）结束后一次性播报。
///
/// 纯函数（供单测）。
String batchDownloadNotificationBody({
  required int succeeded,
  required int failed,
}) {
  if (succeeded > 0 && failed == 0) return '已成功下载 $succeeded 首歌曲';
  if (succeeded == 0) return '下载失败 $failed 首歌曲';
  return '成功下载 $succeeded 首，失败 $failed 首';
}

/// 下载完成通知的抽象（供测试伪造；业务侧只依赖本接口）。
abstract class DesktopDownloadNotifier {
  /// 弹一条系统通知。实现方负责点击行为（如把主窗带到前台）。
  void notifyDownloadCompleted({required String title, required String body});
}

/// 基于 local_notifier 的实现：点击通知把主窗带到前台。
class LocalNotifierDownloadNotifier implements DesktopDownloadNotifier {
  const LocalNotifierDownloadNotifier();

  @override
  void notifyDownloadCompleted({required String title, required String body}) {
    final notification = LocalNotification(
      title: title,
      body: body,
      // 音乐应用：通知不出声，避免打断正在播放的内容。
      silent: true,
    );
    notification.onClick = () => unawaited(_bringMainWindowToFront());
    unawaited(notification.show());
  }

  /// 主窗可能在托盘（隐藏）或最小化：先恢复再置前。
  static Future<void> _bringMainWindowToFront() async {
    try {
      if (await windowManager.isMinimized()) {
        await windowManager.restore();
      }
      await windowManager.show();
      await windowManager.focus();
    } on Exception catch (error) {
      // 置前失败只影响体验，不影响下载结果。
      debugPrint('DesktopSystemIntegration: 通知点击置前失败: $error');
    }
  }
}

/// 批量下载完成聚合器（纯逻辑，可单测）。
///
/// 批量下载按"任务"（一个批次，含地址解析与文件传输）统计，
/// 全部结束后只回调 [onComplete] 一次，避免每曲一弹刷屏。
/// 被跳过（已下载/下载中）的歌曲不计数；全部跳过则不通知。
class BatchDownloadTracker {
  BatchDownloadTracker({required void Function(int succeeded, int failed) onComplete})
    : _onComplete = onComplete;

  final void Function(int succeeded, int failed) _onComplete;

  int _pending = 0;
  int _succeeded = 0;
  int _failed = 0;

  /// 开始一个新批次（清零计数）。
  ///
  /// 每个批次应使用独立的 [BatchDownloadTracker] 实例并作为参数随传输闭包
  /// 传递，并发批次互不串扰；[begin] 用于同一实例复用前的复位。
  void begin() {
    _pending = 0;
    _succeeded = 0;
    _failed = 0;
  }

  /// 一个单元开始（一首歌的完整处理：地址解析 + 文件传输）。
  ///
  /// 每个单元必须恰好调用一次 [trackFinished]（无论成败），计数才守恒。
  void trackStarted() => _pending++;

  /// 一个单元结束。计数归零时触发一次完成回调。
  void trackFinished({required bool succeeded}) {
    if (_pending <= 0) return;
    if (succeeded) {
      _succeeded++;
    } else {
      _failed++;
    }
    _pending--;
    if (_pending == 0) {
      final succeededCount = _succeeded;
      final failedCount = _failed;
      _succeeded = 0;
      _failed = 0;
      if (succeededCount > 0 || failedCount > 0) {
        _onComplete(succeededCount, failedCount);
      }
    }
  }
}

/// 开机自启的抽象（供测试伪造；设置页只依赖本接口）。
abstract class AutoStartManager {
  Future<bool> isEnabled();

  /// 启用/禁用开机自启。失败时抛异常，由调用方回滚 UI 状态。
  Future<void> setEnabled(bool enabled);
}

/// 基于 launch_at_startup 的实现（Windows 写注册表 Run 键）。
class LaunchAtStartupManager implements AutoStartManager {
  bool _setupDone = false;

  void _ensureSetup() {
    if (_setupDone) return;
    launchAtStartup.setup(
      appName: AppConfig.appName,
      // launch_at_startup 0.3.1 的 Windows 实现把 appPath 原样写入
      // HKCU\...\CurrentVersion\Run，不加引号（上游已知问题）：安装到
      // 含空格目录（如 C:\Program Files\）时 Windows 会把路径在第一个
      // 空格处截断解析，自启失效。这里主动传入带引号的路径规避；
      // isEnabled 的比对同样基于这个值，enable/查询两侧一致。
      appPath: Platform.isWindows
          ? '"${Platform.resolvedExecutable}"'
          : Platform.resolvedExecutable,
    );
    _setupDone = true;
  }

  @override
  Future<bool> isEnabled() {
    _ensureSetup();
    return launchAtStartup.isEnabled();
  }

  @override
  Future<void> setEnabled(bool enabled) async {
    _ensureSetup();
    if (enabled) {
      await launchAtStartup.enable();
    } else {
      await launchAtStartup.disable();
    }
  }
}

/// 当前生效的开机自启管理器：桌面设置页默认用真实实现；
/// 测试可注入 fake（模式同 debugDesktopFormFactorOverride）。
AutoStartManager autoStartManager = LaunchAtStartupManager();

/// 主窗标题随播放变化的绑定器。
///
/// 泛化依赖 [Listenable] + 取值回调，避免 services 层反向依赖控制器；
/// main.dart 与 PlayerController 接线，测试可用自定义 Listenable 与
/// [setTitle] 伪造收集调用。
class DesktopWindowTitleBinder {
  DesktopWindowTitleBinder({
    required this.titleOf,
    required this.artistOf,
    this.appName = AppConfig.appName,
    Future<void> Function(String title)? setTitle,
  }) : _setTitle = setTitle;

  /// 当前歌名（null/空表示无播放，标题回落为应用名）。
  final String? Function() titleOf;

  /// 当前歌手名。
  final String? Function() artistOf;

  final String appName;

  final Future<void> Function(String title)? _setTitle;

  Listenable? _listenable;
  VoidCallback? _listener;
  String? _lastTitle;

  /// 监听 [listenable] 并立即同步一次标题。重复调用会先解除旧监听。
  void attach(Listenable listenable) {
    detach();
    _listenable = listenable;
    _listener = _update;
    listenable.addListener(_listener!);
    _update();
  }

  /// 解除监听（持有方 dispose 时必须调用）。
  void detach() {
    final listenable = _listenable;
    final listener = _listener;
    if (listenable != null && listener != null) {
      listenable.removeListener(listener);
    }
    _listenable = null;
    _listener = null;
  }

  void _update() {
    final next = formatDesktopWindowTitle(
      songTitle: titleOf(),
      artist: artistOf(),
      appName: appName,
    );
    // 歌名未变（如进度/音量通知）不重复调用平台通道。
    if (next == _lastTitle) return;
    _lastTitle = next;
    final setter =
        _setTitle ??
        (String title) => windowManager.setTitle(title);
    unawaited(setter(next));
  }
}
