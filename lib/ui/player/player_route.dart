import 'package:flutter/material.dart';

import '../../controllers/auth_controller.dart';
import '../../controllers/player_controller.dart';
import '../../controllers/theme_controller.dart';
import '../form_factor.dart';
import '../pages/player_page.dart';

class PlayerPageRoute<T> extends PageRouteBuilder<T> {
  PlayerPageRoute({
    required WidgetBuilder builder,
    super.settings,
  }) : super(
          opaque: false, // 关键：使底层页面保持渲染可见
          barrierColor: Colors.black45, // 类似 QQ 音乐轻微压暗
          barrierDismissible: false,
          pageBuilder: (context, animation, secondaryAnimation) =>
              builder(context),
          transitionsBuilder:
              (context, animation, secondaryAnimation, child) {
            return SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 1),
                end: Offset.zero,
              ).animate(
                CurvedAnimation(
                  parent: animation,
                  curve: Curves.easeOutCubic,
                  reverseCurve: Curves.easeInCubic,
                ),
              ),
              child: child,
            );
          },
          transitionDuration: const Duration(milliseconds: 300),
          reverseTransitionDuration: const Duration(milliseconds: 250),
        );

  /// 跨平台自适应打开播放页：PC 桌面端或车机横屏双拼模式走普通 MaterialPageRoute，移动端竖屏走 PlayerPageRoute
  static Future<T?> open<T>(
    BuildContext context, {
    required PlayerController player,
    required AuthController auth,
  }) {
    final size = MediaQuery.sizeOf(context);
    final landscape = size.width > size.height;
    final isCarMode = ThemeController.instance.carModeEnabled;

    if (isDesktopFormFactor || (landscape && isCarMode)) {
      return Navigator.of(context).push<T>(
        DesktopPlayerPageRoute<T>(
          builder: (_) => PlayerPage(player: player, auth: auth),
        ),
      );
    }
    return Navigator.of(context).push<T>(
      PlayerPageRoute(
        builder: (_) => PlayerPage(player: player, auth: auth),
      ),
    );
  }
}

/// PC 桌面端/车机横屏的整屏播放页路由。
///
/// 与 [MaterialPageRoute] 渲染行为完全一致，仅增加可类型识别：桌面 Shell
/// 需要判断"根导航顶层是否是播放页"（如桌面歌词「更多设置」要先退出
/// 播放页，设置页才不会被整屏播放页盖住）。
class DesktopPlayerPageRoute<T> extends MaterialPageRoute<T> {
  DesktopPlayerPageRoute({required super.builder});
}

/// 根导航顶层若为播放页路由则将其退出。
///
/// 返回是否发生了退出。供"要推入内容区导航的整屏设置页"入口使用：
/// 播放页是根导航整屏路由，会盖住内层内容导航里的页面，先退出才能
/// 让设置页可见（桌面歌词悬浮窗/托盘的「更多设置」即此场景）。
bool popPlayerRouteIfTop(BuildContext context) {
  final rootNav = Navigator.of(context, rootNavigator: true);
  var topIsPlayer = false;
  // 仅访问栈顶路由做类型判断：谓词恒真 → 不触发任何真正 pop。
  rootNav.popUntil((route) {
    topIsPlayer = route is PlayerPageRoute || route is DesktopPlayerPageRoute;
    return true;
  });
  if (topIsPlayer) {
    rootNav.pop();
  }
  return topIsPlayer;
}
