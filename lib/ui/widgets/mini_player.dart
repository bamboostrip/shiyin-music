import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../controllers/auth_controller.dart';
import '../../controllers/player_controller.dart';
import '../../controllers/theme_controller.dart';
import '../form_factor.dart';
import '../player/player_route.dart';
import 'now_playing_disc.dart';

/// 详情页底部悬浮唱片（对齐上游 3.2.0 的 Floating Disc Pod）。
///
/// 只保留一个圆盘：外圈环形播放进度 + 内部旋转封面；点击进播放页、
/// 长按播放/暂停。上游用 BackdropFilter 做液态玻璃，本 fork 已在 388ad96
/// 为车机/低端机移除迷你条的离屏 blur，这里用实色盘体 + 同款阴影/描边，
/// 视觉语言与首页悬浮底栏一致且零离屏合成。
class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key, required this.player, required this.auth});

  final PlayerController player;
  final AuthController auth;

  /// 悬浮盘外径（与上游一致 58）。
  static const double podSize = 58;

  /// 外圈进度环直径。
  static const double ringSize = 46;

  /// 内部封面直径（旋转部分）。
  static const double coverSize = 38;

  void _openPlayer(BuildContext context) {
    PlayerPageRoute.open(context, player: player, auth: auth);
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final isLandscape = size.width > size.height;
    // 仅车机模式隐藏（由左侧播放面板替代）；普通横屏仍显示。
    if (isLandscape && ThemeController.instance.carModeEnabled) {
      return const SizedBox.shrink();
    }

    // 高频响应 player 更新，仅桌面 Windows 排除语义树
    // （AXTree 竞态）；移动端保留 TalkBack 可读。
    return ExcludeSemantics(
      excluding: isDesktopPlatform,
      child: AnimatedBuilder(
        animation: player,
        builder: (context, _) {
          final song = player.currentSong;
          if (song == null) {
            return const SizedBox.shrink();
          }
          final colorScheme = Theme.of(context).colorScheme;
          final isDark = Theme.of(context).brightness == Brightness.dark;
          return Align(
            alignment: Alignment.bottomCenter,
            // heightFactor: 1 —— 调用方常把它放进 Align/Positioned 的宽松
            // 高度约束里；不收缩的话本组件会撑满整屏，点击热区与定位都会错。
            heightFactor: 1,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _openPlayer(context),
              onLongPress: () {
                HapticFeedback.lightImpact();
                player.togglePlay();
              },
              child: Container(
                width: podSize,
                height: podSize,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isDark ? const Color(0xFF1E2433) : Colors.white,
                  border: Border.all(
                    color: isDark
                        ? Colors.white.withValues(alpha: .12)
                        : colorScheme.outlineVariant.withValues(alpha: .5),
                    width: 1,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: isDark ? .30 : .14),
                      blurRadius: 18,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: Center(
                  child: NowPlayingDisc(
                    player: player,
                    ringSize: ringSize,
                    coverSize: coverSize,
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// 悬浮唱片的挂载点：统一门控「桌面形态不挂载」。
///
/// 桌面形态（Windows/macOS/Linux）内容区底部常驻 `DesktopPlayerBar`，
/// 详情页再挂 [MiniPlayer] 会在同一竖排叠出上下两条播放栏，而 PC 上只应
/// 保留底部那一条。判定收敛到本组件，页面只管挂载、无需各自重复写
/// `if (!isDesktopFormFactor)`（散落判断易漏改，正是本次问题的成因）。
///
/// 移动端/车机形态（`isDesktopFormFactor == false`）渲染结果与直接挂
/// [MiniPlayer] 完全一致，行为零变化。
class MiniPlayerSlot extends StatelessWidget {
  const MiniPlayerSlot({super.key, required this.player, required this.auth});

  final PlayerController player;
  final AuthController auth;

  @override
  Widget build(BuildContext context) {
    if (isDesktopFormFactor) {
      return const SizedBox.shrink();
    }
    return MiniPlayer(player: player, auth: auth);
  }
}
