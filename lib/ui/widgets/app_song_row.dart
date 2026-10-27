import 'package:flutter/material.dart';

import '../../controllers/player_controller.dart';
import '../../models/music_models.dart';
import 'artwork.dart';
import 'marquee_text.dart';
import 'now_playing_badge.dart';
import 'toast.dart';

/// 移动端统一歌曲行（歌单 / 搜索结果 / 歌手页共用；桌面端表格不动）。
///
/// 扁平无卡片：常态透明、无边框无阴影，行间只靠呼吸间距分隔。
/// 几何：46 封面（8 圆角）+ 15px w600 标题 + 12px 副标题 + 右侧操作槽；
/// 播中行标题染主题色（超长跑马灯）+ 封面右下律动标 + 8% 主色底。
class AppSongRow extends StatefulWidget {
  const AppSongRow({
    super.key,
    required this.song,
    required this.player,
    required this.onTap,
    this.subtitle,
    this.leading,
    this.trailing = const [],
    this.highlighted = false,
    this.excludeSemantics = false,
    this.showDownloadedBadge = true,
  });

  final Song song;
  final PlayerController player;
  final VoidCallback onTap;

  /// 副标题文案；为 null 时用歌手名。
  final String? subtitle;

  /// 前置槽（如多选复选框），为 null 时不占位。
  final Widget? leading;

  /// 右侧操作槽（如更多按钮、红心）。
  final List<Widget> trailing;

  /// 高亮底（如多选中态）：10% 主色底，优先于播中态。
  final bool highlighted;
  final bool excludeSemantics;

  /// 是否在封面左下角显示「已下载」角标（默认显示）。
  ///
  /// 「已下载」「本地音乐」等整页都是本地文件的列表里传 false：
  /// 每行都挂角标纯属冗余；歌单/搜索/歌手页等混合来源列表用默认值。
  final bool showDownloadedBadge;

  @override
  State<AppSongRow> createState() => _AppSongRowState();
}

class _AppSongRowState extends State<AppSongRow> {
  var _hovering = false;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // 歌曲行响应 player 重建，高频更新会触发 Windows AXTree 竞态崩溃，
    // 调用方按平台决定是否排除（歌单页仅桌面平台排除；移动端保留无障碍）。
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: ExcludeSemantics(
        excluding: widget.excludeSemantics,
        child: AnimatedBuilder(
          animation: widget.player,
          builder: (context, _) {
            final song = widget.song;
            final player = widget.player;
            final active = player.currentSong?.hash == song.hash;
            final activeColor = colorScheme.primary;
            final bgColor = widget.highlighted
                ? activeColor.withValues(alpha: .10)
                : active
                    ? activeColor.withValues(alpha: .08)
                    : _hovering
                        ? (isDark
                            ? Colors.white.withValues(alpha: .06)
                            : colorScheme.surfaceContainerHighest
                                .withValues(alpha: .5))
                        : Colors.transparent;
            return Container(
              decoration: BoxDecoration(
                color: bgColor,
                borderRadius: BorderRadius.circular(10),
              ),
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: widget.onTap,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 4, vertical: 7),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      if (widget.leading != null) ...[
                        widget.leading!,
                        const SizedBox(width: 8),
                      ],
                      SizedBox.square(
                        dimension: 46,
                        child: Stack(
                          children: [
                            Artwork(
                              url: song.coverUrl,
                              size: 46,
                              borderRadius: 8,
                            ),
                            // 左下角「已下载」角标；右下角已有播中律动标，两者
                            // 分居两侧不重叠。
                            if (widget.showDownloadedBadge)
                              Positioned(
                                left: 3,
                                bottom: 3,
                                child: _DownloadedBadge(
                                  player: player,
                                  song: song,
                                ),
                              ),
                            if (active)
                              Positioned(
                                right: 3,
                                bottom: 3,
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    color: colorScheme.surface
                                        .withValues(alpha: .92),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Padding(
                                    padding: const EdgeInsets.all(2),
                                    child: NowPlayingBadge(
                                      active: active,
                                      playing: player.isPlaying,
                                      color: activeColor,
                                      size: 12,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // 全部行都用 MarqueeText：文本放得下时它内部直接
                            // 渲染静态 Text.rich（零动画开销），放不下才滚动。
                            // 之前只有 active 行用跑马灯，其余长歌名一律被
                            // ellipsis 截断。
                            MarqueeText.text(
                              song.title,
                              style: Theme.of(context)
                                  .textTheme
                                  .bodyLarge
                                  ?.copyWith(
                                    color: active ? activeColor : null,
                                    fontWeight: FontWeight.w600,
                                    fontSize: 15,
                                  ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              widget.subtitle ?? song.artist,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(
                                    color: active
                                        ? activeColor.withValues(alpha: .72)
                                        : colorScheme.onSurfaceVariant,
                                  ),
                            ),
                          ],
                        ),
                      ),
                      if (widget.trailing.isNotEmpty) ...[
                        const SizedBox(width: 4),
                        ...widget.trailing,
                      ],
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// 封面左下角「已下载」角标。
///
/// 刻意做成独立 widget 并只订阅下载控制器：下载进度（每 tick notify）
/// 只重建这枚 16px 角标，不会带着整行（跑马灯/封面/操作槽）一起重建；
/// [PlayerController.downloadController] 未注入（单测 / 初始化早期）时
/// 静默隐藏，不抛错。
class _DownloadedBadge extends StatelessWidget {
  const _DownloadedBadge({required this.player, required this.song});

  final PlayerController player;
  final Song song;

  @override
  Widget build(BuildContext context) {
    final downloads = player.downloadController;
    if (downloads == null) return const SizedBox.shrink();
    return AnimatedBuilder(
      animation: downloads,
      builder: (context, _) {
        if (!downloads.isDownloaded(song)) return const SizedBox.shrink();
        final colorScheme = Theme.of(context).colorScheme;
        // 与右下角播中标同款「92% surface 底 + 圆角 6 容器」写法，
        // 绿色 check 沿用下载完成语义色。
        return Tooltip(
          message: '已下载',
          child: Material(
            color: colorScheme.surface.withValues(alpha: .92),
            borderRadius: BorderRadius.circular(6),
            child: InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: () => Toast.info('已下载，播放时将优先使用本地文件'),
              child: const Padding(
                padding: EdgeInsets.all(2),
                child: Icon(
                  Icons.check_rounded,
                  size: 12,
                  color: Color(0xFF24C768),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 歌曲行统一更多按钮：竖排 ⋮、19px、55% 次级字色、紧凑密度。
class AppSongRowMenuButton extends StatelessWidget {
  const AppSongRowMenuButton({super.key, required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return IconButton(
      tooltip: '更多',
      visualDensity: VisualDensity.compact,
      iconSize: 19,
      color: colorScheme.onSurfaceVariant.withValues(alpha: .55),
      onPressed: onPressed,
      icon: const Icon(Icons.more_vert_rounded),
    );
  }
}
