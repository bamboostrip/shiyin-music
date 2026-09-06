import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../controllers/player_controller.dart';
import '../../models/music_models.dart';
import '../player/song_tap_handler.dart';
import 'desktop_anchored_menu.dart';

/// PC 播放队列面板首选尺寸（逻辑像素）。
const double kDesktopQueuePanelWidth = 360;
const double kDesktopQueuePanelHeight = 480;

/// 队列行高与行间距（固定行高用于"自动滚到正在播放行"的偏移换算）。
const double _kRowHeight = 52;
const double _kRowSpacing = 4;
const double _kRowStride = _kRowHeight + _kRowSpacing;

/// 弹出 PC 播放队列面板：锚定在 [context]（播放条队列按钮）上方、右对齐按钮。
///
/// - 全屏 barrier **视觉透明**，仅用于点击面板外任意处关闭（light dismiss，
///   QQ 音乐/网易云 PC 一致：右下队列是锚定小面板，不压暗背景，可继续看列表）；
/// - Esc 关闭，复用 desktop_anchored_menu 的通用锚定路由；
/// - 定位经 [placeAnchoredPanelAbove]：底缘贴按钮上方、右对齐，
///   四周保留 ≥12px 边距，窗口太小时收缩面板；
/// - 点击行切到该首，行为与移动端 queue_sheet 一致（同一 PlayerController API）。
Future<void> showDesktopQueuePanel(
  BuildContext context,
  PlayerController player,
) {
  return Navigator.of(context, rootNavigator: true).push(
    DesktopAnchoredPopupRoute<void>(
      anchor: anchorAboveRight(context),
      placement: (anchor, panelSize, screenSize) => placeAnchoredPanelAbove(
        anchor: anchor,
        panelSize: panelSize,
        screenSize: screenSize,
      ),
      menuBuilder: (_) => DesktopQueuePanel(player: player),
      scrimColor: Colors.transparent,
      barrierLabel: '关闭播放队列',
    ),
  );
}

/// PC 播放队列锚定面板：标题行（“播放队列 N 首” + 收起）+ 可滚动队列列表。
///
/// 行 = 序号或“正在播放”指示、歌名-歌手、时长；当前播放行高亮，
/// 行 hover 高亮；不提供 queue_sheet 之外的额外操作（无清空/删除）。
class DesktopQueuePanel extends StatefulWidget {
  const DesktopQueuePanel({super.key, required this.player});

  final PlayerController player;

  @override
  State<DesktopQueuePanel> createState() => _DesktopQueuePanelState();
}

class _DesktopQueuePanelState extends State<DesktopQueuePanel> {
  late final ScrollController _scrollController;

  @override
  void initState() {
    super.initState();
    final activeIndex = _indexOfCurrent();
    _scrollController = ScrollController(
      // 粗略初值：正在播放行上方每行一个步长；首帧布局后按可视区精确居中校正。
      initialScrollOffset: math.max(0.0, activeIndex * _kRowStride),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToActive());
  }

  int _indexOfCurrent() {
    final current = widget.player.currentSong;
    if (current == null) return -1;
    // 空 hash 本地歌用 id 回退，避免空串全等误伤首行
    return widget.player.queue.indexWhere((song) => isSameSong(current, song));
  }

  void _scrollToActive() {
    if (!mounted || !_scrollController.hasClients) return;
    final position = _scrollController.position;
    final activeIndex = _indexOfCurrent();
    if (activeIndex < 0) return;
    final target =
        (activeIndex * _kRowStride - (position.viewportDimension - _kRowHeight) / 2)
            .clamp(0.0, position.maxScrollExtent);
    _scrollController.jumpTo(target);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: colorScheme.surface,
      elevation: 12,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: kDesktopQueuePanelWidth,
        height: kDesktopQueuePanelHeight,
        child: AnimatedBuilder(
          animation: widget.player,
          builder: (context, _) {
            final player = widget.player;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                  child: Row(
                    children: [
                      Text(
                        '播放队列',
                        style: Theme.of(context)
                            .textTheme
                            .titleMedium
                            ?.copyWith(fontWeight: FontWeight.w900),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '${player.queue.length} 首',
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: colorScheme.onSurfaceVariant),
                      ),
                      const Spacer(),
                      IconButton(
                        tooltip: '收起',
                        visualDensity: VisualDensity.compact,
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.keyboard_arrow_down_rounded),
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ],
                  ),
                ),
                Divider(
                  height: 1,
                  thickness: 1,
                  color: colorScheme.outlineVariant.withValues(alpha: .5),
                ),
                Expanded(child: _buildList(context, player, colorScheme)),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildList(
    BuildContext context,
    PlayerController player,
    ColorScheme colorScheme,
  ) {
    if (player.queue.isEmpty) {
      return Center(
        child: Text(
          '播放队列为空',
          style: Theme.of(context)
              .textTheme
              .bodyMedium
              ?.copyWith(color: colorScheme.onSurfaceVariant),
        ),
      );
    }
    final current = player.currentSong;
    return ListView.separated(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      itemCount: player.queue.length,
      separatorBuilder: (_, _) => const SizedBox(height: _kRowSpacing),
      itemBuilder: (context, index) {
        final song = player.queue[index];
        final active = isSameSong(current, song);
        return _DesktopQueueRow(
          song: song,
          index: index + 1,
          active: active,
          isPlaying: active && player.isPlaying,
          onTap: () {
            // 点当前行只关面板（桌面单击选中语义下也不重头播）
            if (isSameSong(player.currentSong, song)) {
              Navigator.of(context).pop();
              return;
            }
            Navigator.of(context).pop();
            player.playSong(song, queue: player.queue);
          },
        );
      },
    );
  }
}

/// 队列行：序号 / 正在播放指示 + 歌名-歌手 + 时长；hover 高亮、点击切歌。
class _DesktopQueueRow extends StatefulWidget {
  const _DesktopQueueRow({
    required this.song,
    required this.index,
    required this.active,
    required this.isPlaying,
    required this.onTap,
  });

  final Song song;
  final int index;
  final bool active;
  final bool isPlaying;
  final VoidCallback onTap;

  @override
  State<_DesktopQueueRow> createState() => _DesktopQueueRowState();
}

class _DesktopQueueRowState extends State<_DesktopQueueRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          height: _kRowHeight,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: widget.active
                ? colorScheme.primary.withValues(alpha: .09)
                : _hovered
                    ? colorScheme.onSurface.withValues(alpha: .05)
                    : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 24,
                child: widget.active
                    ? Icon(
                        widget.isPlaying
                            ? Icons.equalizer_rounded
                            : Icons.pause_rounded,
                        size: 16,
                        color: colorScheme.primary,
                      )
                    : Text(
                        '${widget.index}',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                              fontWeight: FontWeight.w700,
                            ),
                      ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.song.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context)
                          .textTheme
                          .titleSmall
                          ?.copyWith(
                            color: widget.active ? colorScheme.primary : null,
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      widget.song.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: widget.active
                                ? colorScheme.primary.withValues(alpha: .72)
                                : colorScheme.onSurfaceVariant,
                          ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                formatDuration(widget.song.duration),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
