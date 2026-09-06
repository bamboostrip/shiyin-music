import 'dart:async';
import 'dart:io' show File, Platform;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:system_tray/system_tray.dart';
import 'package:window_manager/window_manager.dart';

import '../../controllers/player_controller.dart';
import '../../services/desktop_lyrics_service.dart';
import '../form_factor.dart';
import 'desktop_window.dart';

/// Windows 系统托盘常驻（仅桌面形态，由 main.dart 门控调用）。
///
/// - 左键单击：切换主窗显示/隐藏（最小化时恢复窗口）；
/// - 右键单击：弹出菜单（显示/隐藏主窗、播放/暂停、上一首、下一首、
///   「桌面歌词」勾选项、解锁桌面歌词、退出）；
/// - 「桌面歌词」：勾选态跟随 [PlayerController.desktopLyricsEnabled]，
///   点击切换悬浮窗显示/隐藏；
/// - "退出"：先立即落盘窗口几何再销毁窗口。
///
/// 菜单构建一次并持有引用；「桌面歌词」勾选态与「解锁桌面歌词」的可用
/// 状态（仅桌面歌词可见且锁定时可用，QQ 音乐式：解锁入口在主程序）在
/// 每次右键弹出前刷新。
/// [PlayerController] 仅用于弹出前读取实时状态与切换/解锁操作，不持有页面状态。
class DesktopTray {
  DesktopTray._();

  static SystemTray? _tray;
  static Menu? _menu;
  static PlayerController? _player;

  /// 「解锁桌面歌词」菜单项名称（findItemByName 定位后刷新可用态）。
  static const _kUnlockDesktopLyricsItemName = 'unlock_desktop_lyrics';

  /// 「桌面歌词」勾选项名称（findItemByName 定位后刷新勾选态）。
  static const _kDesktopLyricsItemName = 'desktop_lyrics_toggle';

  /// 初始化托盘图标与菜单。重复调用（未 dispose）时直接忽略。
  ///
  /// 托盘初始化失败（个别环境无托盘，initSystemTray 会抛出而非返回
  /// false）时不影响主流程：本会话内关闭"X 最小化到托盘"（会话级降级，
  /// 不回写持久化设置），保证 X 按钮仍可真正退出应用，避免应用不可达。
  static Future<void> init({required PlayerController player}) async {
    if (!isDesktopFormFactor) return;
    if (_tray != null) return;
    _player = player;
    try {
      await _initTray(player);
    } catch (error) {
      // 捕获 Exception 与 Error：托盘失败只降级，不允许中断启动。
      DesktopWindow.setCloseToTraySessionOverride(false);
      debugPrint('DesktopTray: 托盘初始化失败，本会话 X 直接退出: $error');
    }
  }

  static Future<void> _initTray(PlayerController player) async {
    final tray = SystemTray();
    final ok = await tray.initSystemTray(
      // system_tray 在 Windows 上把该路径解析为
      // <exe 目录>/data/flutter_assets/lib/assets/app_icon.ico，
      // 即打包后的资源路径（见包源码 Utils.getIcon）。
      // Linux 端走 StatusNotifier/AppIndicator，按文件系统路径解析：
      // 相对路径会随进程 CWD 漂移（从 .desktop/桌面快捷方式启动时 CWD
      // 通常是 $HOME，图标加载失败），必须给打包内资源的绝对路径。
      iconPath: _trayIconPath(),
      toolTip: DesktopWindow.kWindowTitle,
    );
    if (!ok) {
      // 个别环境下 initSystemTray 返回 false 而非抛出：
      // 统一走 init() 的降级路径（本会话关闭 closeToTray），避免应用不可达。
      throw StateError('initSystemTray returned false');
    }
    final menu = Menu();
    final lyricsSupported = DesktopLyricsService.isSupportedPlatform;
    await menu.buildFrom([
      MenuItemLabel(label: '显示主窗', onClicked: (_) => _showWindow()),
      MenuItemLabel(label: '隐藏主窗', onClicked: (_) => windowManager.hide()),
      MenuSeparator(),
      MenuItemLabel(
        label: '播放/暂停',
        onClicked: (_) => unawaited(player.togglePlay()),
      ),
      MenuItemLabel(
        label: '上一首',
        onClicked: (_) => unawaited(player.previous()),
      ),
      MenuItemLabel(
        label: '下一首',
        onClicked: (_) => unawaited(player.next()),
      ),
      // 桌面歌词子窗依赖 desktop_multi_window + window_manager 的子窗插件
      // 注册（目前仅 Windows runner 配置），未支持平台不展示入口。
      if (lyricsSupported) ...[
        MenuSeparator(),
        MenuItemCheckbox(
          name: _kDesktopLyricsItemName,
          label: '桌面歌词',
          checked: _isDesktopLyricsEnabled(),
          onClicked: (_) => unawaited(_toggleDesktopLyrics()),
        ),
        MenuItemLabel(
          name: _kUnlockDesktopLyricsItemName,
          label: '解锁桌面歌词',
          enabled: _canUnlockDesktopLyrics(),
          onClicked: (_) => unawaited(_unlockDesktopLyrics()),
        ),
      ],
      MenuSeparator(),
      MenuItemLabel(label: '退出', onClicked: (_) => unawaited(_exit())),
    ]);
    await tray.setContextMenu(menu);
    _menu = menu;
    tray.registerSystemTrayEventHandler((eventName) {
      if (eventName == kSystemTrayEventClick) {
        unawaited(_toggleWindowVisibility());
      } else if (eventName == kSystemTrayEventRightClick) {
        // Windows 右键只派发事件，弹出菜单需主动调用；
        // 弹出前刷新「桌面歌词」勾选态与「解锁桌面歌词」可用态
        // （菜单只构建一次）。
        unawaited(_popUpContextMenu());
      }
    });
    _tray = tray;
  }

  /// Linux 托盘图标路径：优先打包内资源的绝对路径（相对路径随 CWD 漂移，
  /// 从 .desktop 启动时 CWD 是 $HOME 会加载失败）；dev 运行（flutter run）
  /// 与打包布局都是 `<exe目录>/data/flutter_assets/...`，探测失败回退相对路径。
  static String _trayIconPath() {
    if (!Platform.isLinux) return 'lib/assets/app_icon.ico';
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final candidates = [
      '$exeDir/data/flutter_assets/lib/assets/logo.png',
      // AppImage 挂载点：主程序在 usr/bin，资源在 usr/share（本项目未用，
      // 预留兼容）。
      '$exeDir/../../usr/share/flutter_assets/lib/assets/logo.png',
    ];
    for (final candidate in candidates) {
      if (File(candidate).existsSync()) return candidate;
    }
    return 'lib/assets/logo.png';
  }

  /// 桌面歌词开关当前状态（跟随 PlayerController，托盘不另存状态）。
  static bool _isDesktopLyricsEnabled() {
    final player = _player;
    if (player == null) return false;
    return player.desktopLyricsEnabled;
  }

  /// 托盘切换桌面歌词：走统一设置更新路径（持久化 + 通知设置页 + 回推子窗）。
  /// 权限失败时 setDesktopLyricsEnabled 内部会回退为关，随后刷新勾选态
  /// 保证菜单与真实状态一致。
  static Future<void> _toggleDesktopLyrics() async {
    final player = _player;
    if (player == null) return;
    await player.setDesktopLyricsEnabled(!player.desktopLyricsEnabled);
    await _refreshDesktopLyricsCheckState();
  }

  /// 把「桌面歌词」勾选态刷新为当前实际状态。
  static Future<void> _refreshDesktopLyricsCheckState() async {
    final item = _menu?.findItemByName<MenuItemCheckbox>(
      _kDesktopLyricsItemName,
    );
    if (item == null) return;
    final checked = _isDesktopLyricsEnabled();
    if (item.checked != checked) {
      await item.setCheck(checked);
    }
  }

  /// 仅当桌面歌词可见且锁定时允许解锁（QQ 音乐式基准）。
  static bool _canUnlockDesktopLyrics() {
    final player = _player;
    if (player == null) return false;
    return player.desktopLyricsEnabled && player.desktopLyricsSettings.locked;
  }

  /// 弹出前刷新「桌面歌词」勾选态与「解锁桌面歌词」可用态，再弹出右键菜单。
  static Future<void> _popUpContextMenu() async {
    final tray = _tray;
    if (tray == null) return;
    try {
      final item = _menu?.findItemByName<MenuItemLabel>(
        _kUnlockDesktopLyricsItemName,
      );
      final canUnlock = _canUnlockDesktopLyrics();
      if (item != null && item.enabled != canUnlock) {
        await item.setEnable(canUnlock);
      }
      await _refreshDesktopLyricsCheckState();
    } on Exception catch (e) {
      // 刷新失败只影响置灰/勾选展示，不阻断菜单弹出。
      debugPrint('DesktopTray: 刷新桌面歌词菜单项失败: $e');
    }
    try {
      await tray.popUpContextMenu();
    } on Exception catch (e) {
      // Explorer 重启/托盘已死时弹出可能失败：吞掉避免未捕获异步异常。
      debugPrint('DesktopTray: 弹出托盘菜单失败: $e');
    }
  }

  /// 托盘解锁桌面歌词：走统一设置更新路径（持久化 + 通知设置页 + 回推子窗）。
  static Future<void> _unlockDesktopLyrics() async {
    final player = _player;
    if (player == null || !_canUnlockDesktopLyrics()) return;
    await player.updateDesktopLyricsSettings(
      player.desktopLyricsSettings.copyWith(locked: false),
    );
  }

  /// 销毁托盘图标。
  static Future<void> dispose() async {
    final tray = _tray;
    _tray = null;
    _menu = null;
    _player = null;
    await tray?.destroy();
  }

  static Future<void> _showWindow() async {
    await windowManager.show();
    await windowManager.focus();
  }

  static Future<void> _toggleWindowVisibility() async {
    // isVisible 在窗口最小化时仍返回 true：需先检查最小化状态，
    // 左键单击应恢复窗口而不是把最小化窗口再隐藏一次。
    if (await windowManager.isMinimized()) {
      await windowManager.restore();
      await _showWindow();
      return;
    }
    if (await windowManager.isVisible()) {
      await windowManager.hide();
    } else {
      await _showWindow();
    }
  }

  static Future<void> _exit() async {
    // 统一退出路径：清理钩子（关歌词子窗、销毁托盘）→ 落盘几何 → 销毁。
    // 不直接 destroy——PostQuitMessage 会硬杀进程，托盘图标与子窗来不及
    // 清理（托盘"退出"来自菜单回调，此时 _tray 仍存活，正好在钩子里销毁）。
    await DesktopWindow.quitGracefully();
  }
}
