import 'package:flutter/material.dart';

import '../../controllers/auth_controller.dart';
import '../../controllers/player_controller.dart';
import '../../controllers/theme_controller.dart';
import '../../models/music_models.dart';
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
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF1E2433) : Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isDark
                ? Colors.white.withValues(alpha: .12)
                : colorScheme.outlineVariant.withValues(alpha: .5),
            width: 1,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? .28 : .12),
              blurRadius: 16,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            onTap: onTap,
            child: SizedBox(
              height: 64,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: Column(
                      children: [
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(8, 7, 8, 8),
                            child: Row(
                              children: [
                                Artwork(
                                  url: song.coverUrl,
                                  size: 48,
                                  borderRadius: 6,
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    mainAxisAlignment:
                                        MainAxisAlignment.center,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      // 长歌名不再被 ellipsis 截断；放得下时
                                      // MarqueeText 内部零开销地退化为静态文本。
                                      MarqueeText.text(
                                        song.title,
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleSmall
                                            ?.copyWith(
                                              fontWeight: FontWeight.w900,
                                              fontSize: 16,
                                            ),
                                      ),
                                      Text(
                                        song.artist,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall
                                            ?.copyWith(
                                              color: colorScheme
                                                  .onSurfaceVariant,
                                              fontWeight: FontWeight.w600,
                                              fontSize: 14,
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
                                      onPressed: player.isPreparing
                                          ? null
                                          : player.togglePlay,
                                      icon: Icon(
                                        player.isPlaying
                                            ? Icons.pause_rounded
                                            : Icons.play_arrow_rounded,
                                        color: colorScheme.onSurface,
                                        size: 30,
                                      ),
                                    );
                                  },
                                ),
                                IconButton(
                                  tooltip: '播放队列',
                                  onPressed: onShowQueue,
                                  icon: Icon(
                                    Icons.queue_music_rounded,
                                    color: colorScheme.onSurface,
                                    size: 29,
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
                            return Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                LinearProgressIndicator(
                                  value: progress,
                                  minHeight: 2,
                                  color: colorScheme.primary,
                                  backgroundColor:
                                      colorScheme.primary.withValues(
                                    alpha: .12,
                                  ),
                                ),
                                if (player.errorMessage case final message?)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 2),
                                    child: Text(
                                      message,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: colorScheme.error,
                                        fontSize: 10,
                                      ),
                                    ),
                                  ),
                              ],
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
