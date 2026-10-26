import 'package:flutter/material.dart';

import '../../controllers/auth_controller.dart';
import '../../controllers/player_controller.dart';
import '../../controllers/theme_controller.dart';
import '../../models/music_models.dart';
import '../design_tokens.dart';
import '../form_factor.dart';
import '../player/player_route.dart';
import 'artwork.dart';
import 'marquee_text.dart';
import 'queue_sheet.dart';

/// 迷你播放条本体（悬浮胶囊）。
///
/// 页面挂载请使用 [MiniPlayerSlot]——它负责「桌面形态不显示」的门控，
/// 避免 PC 端内容区底部与常驻 `DesktopPlayerBar` 叠出上下两条播放栏。
class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key, required this.player, required this.auth});

  final PlayerController player;
  final AuthController auth;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final isLandscape = size.width > size.height;
    // 仅车机模式隐藏（由左侧播放面板替代）；普通横屏仍显示。
    if (isLandscape && ThemeController.instance.carModeEnabled) {
      return const SizedBox.shrink();
    }

    // 迷你栏高频响应 player 更新，仅桌面 Windows 排除语义树
    // （AXTree 竞态）；移动端保留 TalkBack 可读
    return ExcludeSemantics(
      excluding: isDesktopPlatform,
      child: AnimatedBuilder(
        animation: player,
        builder: (context, _) {
          final song = player.currentSong;
          if (song == null) {
            return const SizedBox.shrink();
          }
          return _MiniPlayerContent(
            song: song,
            player: player,
            onTap: () => PlayerPageRoute.open(
              context,
              player: player,
              auth: auth,
            ),
            onShowQueue: () => showQueueSheet(context, player),
          );
        },
      ),
    );
  }
}

class _MiniPlayerContent extends StatelessWidget {
  const _MiniPlayerContent({
    required this.song,
    required this.player,
    required this.onTap,
    required this.onShowQueue,
  });

  final Song song;
  final PlayerController player;
  final VoidCallback onTap;
  final VoidCallback onShowQueue;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
      child: Container(
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF1E2433) : Colors.white,
          borderRadius: BorderRadius.circular(AppRadius.pill),
          border: Border.all(
            color: isDark
                ? Colors.white.withValues(alpha: .12)
                : colorScheme.outlineVariant.withValues(alpha: .5),
            width: 1,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? .28 : .12),
              // 与首页悬浮底栏同一套投影（blur 18 / offset (0,8)）。
              blurRadius: 18,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.pill),
          child: InkWell(
            onTap: onTap,
            child: SizedBox(
              height: 58,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: Column(
                      children: [
                        Expanded(
                          child: Padding(
                            // 胶囊圆角在 58 高下被钳到 29：y=5 处端部内切到
                            // x≈13dp，内部横向留 16 让封面/操作按钮完全躲开
                            // 圆弧，避免大圆角把内容斜切掉一角。
                            padding: const EdgeInsets.fromLTRB(16, 5, 16, 5),
                            child: Row(
                              children: [
                                Artwork(
                                  url: song.coverUrl,
                                  size: 40,
                                  borderRadius: 8,
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    mainAxisAlignment:
                                        MainAxisAlignment.center,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      // 长歌名不再被 ellipsis 截断；放得下时
                                      // MarqueeText 内部零开销地退化为静态文本。
                                      // 精致化：标题 14/w700、副标题 12/w500，
                                      // 比原 16/w900 + 14/w600 更轻、更接近主流
                                      // 音乐 App 迷你条的字阶（用户反馈太大）。
                                      MarqueeText.text(
                                        song.title,
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleSmall
                                            ?.copyWith(
                                              fontWeight: FontWeight.w700,
                                              fontSize: 14,
                                            ),
                                      ),
                                      // 播放错误占用副标题槽位（红色），不再在
                                      // 进度条下方追加一行：58 高的胶囊放不下
                                      // 第三行，追加会把 Row 挤溢出（历史隐患）。
                                      Text(
                                        player.errorMessage ?? song.artist,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall
                                            ?.copyWith(
                                              color:
                                                  player.errorMessage != null
                                                  ? colorScheme.error
                                                  : colorScheme
                                                        .onSurfaceVariant,
                                              fontWeight: FontWeight.w500,
                                              fontSize: 12,
                                            ),
                                      ),
                                    ],
                                  ),
                                ),
                                AnimatedBuilder(
                                  animation: player,
                                  builder: (context, _) {
                                    return IconButton(
                                      tooltip: player.isPlaying
                                          ? '暂停'
                                          : '播放',
                                      visualDensity: VisualDensity.compact,
                                      onPressed: player.isPreparing
                                          ? null
                                          : player.togglePlay,
                                      icon: Icon(
                                        player.isPlaying
                                            ? Icons.pause_rounded
                                            : Icons.play_arrow_rounded,
                                        color: colorScheme.onSurface,
                                        size: 26,
                                      ),
                                    );
                                  },
                                ),
                                IconButton(
                                  tooltip: '播放队列',
                                  visualDensity: VisualDensity.compact,
                                  onPressed: onShowQueue,
                                  icon: Icon(
                                    Icons.queue_music_rounded,
                                    color: colorScheme.onSurface,
                                    size: 24,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        ValueListenableBuilder<Duration>(
                          valueListenable: player.positionListenable,
                          builder: (context, pos, _) {
                            final progress =
                                player.duration.inMilliseconds == 0
                                    ? 0.0
                                    : (pos.inMilliseconds /
                                            player.duration.inMilliseconds)
                                        .clamp(0.0, 1.0);
                            return Padding(
                              // 底边胶囊圆弧会裁掉通栏 2px 进度条两端，横向
                              // 内缩 24（与底栏左右边距同值）避开斜切。
                              padding: const EdgeInsets.symmetric(
                                horizontal: AppSpacing.xl,
                              ),
                              child: LinearProgressIndicator(
                                value: progress,
                                minHeight: 2,
                                color: colorScheme.primary,
                                backgroundColor: colorScheme.primary.withValues(
                                  alpha: .12,
                                ),
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 悬浮迷你播放条的挂载点：统一门控「桌面形态不挂载」。
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
