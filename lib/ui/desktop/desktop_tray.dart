import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:system_tray/system_tray.dart';
import 'package:window_manager/window_manager.dart';

import '../../controllers/player_controller.dart';
import '../form_factor.dart';
import 'desktop_window.dart';

/// Windows 系统托盘常驻（仅桌面形态，由 main.dart 门控调用）。
///
/// - 左键单击：切换主窗显示/隐藏（最小化时恢复窗口）；
/// - 右键单击：弹出菜单（显示/隐藏主窗、播放/暂停、上一首、下一首、退出）；
/// - "退出"：先立即落盘窗口几何再销毁窗口。
///
/// 不持有任何页面/控制器状态：[PlayerController] 仅由 [init] 的
/// 菜单回调闭包引用，托盘本身不保存。
class DesktopTray {
  DesktopTray._();

  static SystemTray? _tray;

  /// 初始化托盘图标与菜单。重复调用（未 dispose）时直接忽略。
  ///
  /// 托盘初始化失败（个别环境无托盘，initSystemTray 会抛出而非返回
  /// false）时不影响主流程：同时关闭"X 最小化到托盘"，保证 X 按钮
  /// 仍可真正退出应用，避免应用不可达。
  static Future<void> init({required PlayerController player}) async {
    if (!isDesktopFormFactor) return;
    if (_tray != null) return;
    try {
      await _initTray(player);
    } catch (error) {
      // 捕获 Exception 与 Error：托盘失败只降级，不允许中断启动。
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool(DesktopWindow.kCloseToTrayPrefKey, false);
      } on Exception {
        // prefs 写入失败不影响主流程。
      }
      debugPrint('DesktopTray: 托盘初始化失败，已改为 X 直接退出: $error');
    }
  }

  static Future<void> _initTray(PlayerController player) async {
    final tray = SystemTray();
    final ok = await tray.initSystemTray(
      // system_tray 在 Windows 上把该路径解析为
      // <exe 目录>/data/flutter_assets/lib/assets/app_icon.ico，
      // 即打包后的资源路径（见包源码 Utils.getIcon）。
      iconPath: 'lib/assets/app_icon.ico',
      toolTip: DesktopWindow.kWindowTitle,
    );
    if (!ok) {
      // 个别环境下 initSystemTray 返回 false 而非抛出：
      // 统一走 init() 的降级路径（关闭 closeToTray），避免应用不可达。
      throw StateError('initSystemTray returned false');
    }
    final menu = Menu();
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
      MenuSeparator(),
      MenuItemLabel(label: '退出', onClicked: (_) => unawaited(_exit())),
    ]);
    await tray.setContextMenu(menu);
    tray.registerSystemTrayEventHandler((eventName) {
      if (eventName == kSystemTrayEventClick) {
        unawaited(_toggleWindowVisibility());
      } else if (eventName == kSystemTrayEventRightClick) {
        // Windows 右键只派发事件，弹出菜单需主动调用。
        unawaited(tray.popUpContextMenu());
      }
    });
    _tray = tray;
  }

  /// 销毁托盘图标。
  static Future<void> dispose() async {
    final tray = _tray;
    _tray = null;
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
    // 销毁窗口前立即落盘几何（复用 saver 的立即保存，跳过防抖）。
    await DesktopWindow.flushGeometry();
    await windowManager.destroy();
  }
}
