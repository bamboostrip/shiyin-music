import 'package:flutter/material.dart';

import '../../controllers/auth_controller.dart';
import '../../controllers/player_controller.dart';
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

  /// 跨平台自适应打开播放页：桌面端走普通 MaterialPageRoute，移动端走 PlayerPageRoute
  static Future<T?> open<T>(
    BuildContext context, {
    required PlayerController player,
    required AuthController auth,
  }) {
    if (isDesktopFormFactor) {
      return Navigator.of(context).push<T>(
        MaterialPageRoute(
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
