import 'dart:async';

import 'package:flutter/material.dart';

import '../../controllers/auth_controller.dart';
import '../../controllers/player_controller.dart';
import '../../models/music_models.dart';
import '../design_tokens.dart';
import '../form_factor.dart';
import 'desktop_anchored_menu.dart';
import 'now_playing_badge.dart';

/// PC 桌面端专业歌曲表格行通用粘性表头委托（表头高度 36px）。
class DesktopSongTableStickyHeaderDelegate
    extends SliverPersistentHeaderDelegate {
  DesktopSongTableStickyHeaderDelegate({required this.child});

  final Widget child;

  @override
  double get minExtent => 36.0;

  @override
  double get maxExtent => 36.0;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) => child;

  @override
  bool shouldRebuild(
    covariant DesktopSongTableStickyHeaderDelegate oldDelegate,
  ) => child != oldDelegate.child;
}

/// 自定义精致圆形勾选框，用于表格表头「全选」和歌曲行勾选。
class MusicCircleCheckbox extends StatelessWidget {
  const MusicCircleCheckbox({super.key, required this.value, this.onChanged});

  final bool value;
  final ValueChanged<bool?>? onChanged;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final unselectedBorderColor = isDark
        ? Colors.white.withValues(alpha: .32)
        : colorScheme.outlineVariant.withValues(alpha: .95);

    return InkResponse(
      onTap: onChanged == null ? null : () => onChanged!(!value),
      radius: 18,
      containedInkWell: false,
      highlightShape: BoxShape.circle,
      child: SizedBox.square(
        dimension: 32,
        child: Center(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: value ? colorScheme.primary : Colors.transparent,
              border: Border.all(
                color: value ? colorScheme.primary : unselectedBorderColor,
                width: 1.5,
              ),
            ),
            child: value
                ? const Icon(Icons.check_rounded, size: 14, color: Colors.white)
                : null,
          ),
        ),
      ),
    );
  }
}

/// PC 桌面端专业歌曲表格表头（高度 36px）。
///
/// 列宽契约与 [DesktopSongTableRow] 一致：
/// 52px 序号列 / flex4 歌曲 / flex3 歌手 / flex3 专辑 / 140px 时长。
class DesktopSongTableHeader extends StatelessWidget {
  const DesktopSongTableHeader({
    super.key,
    required this.selecting,
    required this.allSelected,
    required this.onToggleSelectAll,
  });

  final bool selecting;
  final bool allSelected;
  final VoidCallback? onToggleSelectAll;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final headerStyle = TextStyle(
      color: colorScheme.onSurfaceVariant.withValues(alpha: 0.8),
      fontSize: 12.5,
      fontWeight: FontWeight.w600,
    );

    return Container(
      height: 36,
      decoration: BoxDecoration(
        color: colorScheme.surface,
        border: Border(
          bottom: BorderSide(
            color: colorScheme.outlineVariant.withValues(alpha: 0.25),
            width: 1,
          ),
        ),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 52,
            child: Center(
              child: selecting
                  ? MusicCircleCheckbox(
                      value: allSelected,
                      onChanged: onToggleSelectAll == null
                          ? null
                          : (_) => onToggleSelectAll!(),
                    )
                  : Text('#', style: headerStyle),
            ),
          ),
          Expanded(
            flex: 4,
            child: Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Text(
                '歌曲标题',
                style: headerStyle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          Expanded(
            flex: 3,
            child: Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Text(
                '歌手',
                style: headerStyle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          Expanded(
            flex: 3,
            child: Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Text(
                '专辑',
                style: headerStyle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          SizedBox(
            width: 140,
            child: Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.only(right: 16),
                child: Text('时长', style: headerStyle),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// PC 桌面端紧凑高密度表格数据行（固定行高 44px）。
class DesktopSongTableRow extends StatefulWidget {
  const DesktopSongTableRow({
    super.key,
    required this.song,
    required this.index,
    required this.player,
    required this.auth,
    required this.canDelete,
    required this.selecting,
    required this.selected,
    required this.isFocused,
    required this.onTap,
    required this.onDoubleTap,
    required this.onPlay,
    required this.onAddToPlaylist,
    required this.onDelete,
    required this.onViewArtist,
    required this.onMore,
    this.onSecondaryMore,
    this.showHoverActions = true,
  });

  final Song song;
  final int index;
  final PlayerController player;
  final AuthController auth;
  final bool canDelete;
  final bool selecting;
  final bool selected;
  final bool isFocused;
  final VoidCallback onTap;
  final VoidCallback onDoubleTap;
  final VoidCallback onPlay;
  final VoidCallback onAddToPlaylist;
  final VoidCallback onDelete;
  final VoidCallback onViewArtist;
  final VoidCallback onMore;

  /// PC 右键 / `...` 按钮触发"更多"时的位置回调（全局坐标），
  /// 用于把歌曲操作菜单锚定到触发点；为空时回退到 [onMore]（无坐标）。
  final void Function(Offset globalPosition)? onSecondaryMore;

  /// 是否在悬停时显示行内操作图标列（播放/收藏/加入歌单/更多）。
  ///
  /// 外部平台歌曲（如网易云）仅支持播放，与移动端卡片行为保持一致：
  /// 悬停时只显示时长、不显示操作图标（右键菜单仍由页面自行决定内容）。
  final bool showHoverActions;

  @override
  State<DesktopSongTableRow> createState() => _DesktopSongTableRowState();
}

class _DesktopSongTableRowState extends State<DesktopSongTableRow> {
  bool _hovering = false;

  void _invokeMore([Offset? anchor]) {
    final void Function(Offset)? positionAware = widget.onSecondaryMore;
    if (positionAware != null && anchor != null) {
      positionAware(anchor);
    } else {
      widget.onMore();
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final song = widget.song;
    final index = widget.index;
    final player = widget.player;
    final auth = widget.auth;
    final canDelete = widget.canDelete;
    final selecting = widget.selecting;
    final selected = widget.selected;
    final isFocused = widget.isFocused;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: ExcludeSemantics(
        // 高频重建 + 桌面平台才排除（Windows AXTree 竞态）；注意原 `!isWindows`
        // 写反了（在 Windows 上保留、在移动端排除），现按注释意图修正
        excluding: isDesktopPlatform,
        child: AnimatedBuilder(
          animation: Listenable.merge([player, auth]),
          builder: (context, _) {
            // hash 非空守卫：本地/占位歌曲可能 hash 为空，空 == 空 会把
            // 所有空 hash 行误判为正在播放（整列表“加粗高亮”假象）。
            final active = !selecting &&
                song.hash.isNotEmpty &&
                player.currentSong?.hash == song.hash;
            final activeColor = colorScheme.primary;

            Color bgColor;
            if (selecting) {
              if (selected) {
                bgColor = activeColor.withValues(alpha: 0.12);
              } else if (_hovering) {
                bgColor = isDark
                    ? Colors.white.withValues(alpha: 0.06)
                    : colorScheme.surfaceContainerHighest.withValues(
                        alpha: 0.7,
                      );
              } else {
                bgColor = Colors.transparent;
              }
            } else {
              if (active) {
                bgColor = activeColor.withValues(alpha: 0.10);
              } else if (isFocused) {
                bgColor = isDark
                    ? Colors.white.withValues(alpha: 0.09)
                    : colorScheme.surfaceContainerHighest.withValues(
                        alpha: 0.85,
                      );
              } else if (_hovering) {
                bgColor = isDark
                    ? Colors.white.withValues(alpha: 0.06)
                    : colorScheme.surfaceContainerHighest.withValues(
                        alpha: 0.7,
                      );
              } else {
                bgColor = Colors.transparent;
              }
            }

            final isLiked = auth.isLiked(song);
            final albumText =
                (song.albumName != null && song.albumName!.trim().isNotEmpty)
                ? song.albumName!
                : '-';
            final titleStyle = TextStyle(
              // 非播放行用 w400 Regular（系统字体原生字重）：w500 在
              // Windows 微软雅黑等仅有 Regular/Bold 的字体上按字形回退合成，
              // 不同汉字合成路径不同，肉眼即“有的细浅、有的粗黑”。
              // 播放行用 w700 Bold（原生粗体）+ 主色高亮，区分明确且渲染一致。
              color: active ? activeColor : colorScheme.onSurface,
              fontSize: 13.5,
              fontWeight: active ? FontWeight.w700 : FontWeight.w400,
            );
            final albumStyle = TextStyle(
              color: colorScheme.onSurfaceVariant.withValues(alpha: 0.75),
              fontSize: 13,
              fontWeight: FontWeight.w400,
            );

            return Container(
              height: 44,
              decoration: BoxDecoration(
                color: bgColor,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: (selecting && selected) || active
                      ? activeColor.withValues(alpha: 0.25)
                      : (isFocused && !active)
                      ? (isDark ? Colors.white : colorScheme.outline)
                            .withValues(alpha: 0.18)
                      : Colors.transparent,
                  width: 1,
                ),
              ),
              child: Stack(
                children: [
                  Positioned.fill(
                    child: Material(
                      color: Colors.transparent,
                      borderRadius: BorderRadius.circular(6),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(6),
                        onTap: widget.onTap,
                        onDoubleTap: widget.onDoubleTap,
                        // PC 右键：在按下时取全局坐标，把菜单锚定到点击处。
                        onSecondaryTapDown: (details) =>
                            _invokeMore(details.globalPosition),
                      ),
                    ),
                  ),
                  Row(
                    children: [
                      // 序号 / 复选框列（52px 居中）
                      SizedBox(
                        width: 52,
                        child: IgnorePointer(
                          child: Center(
                            child: selecting
                                ? MusicCircleCheckbox(
                                    value: selected,
                                    onChanged: null,
                                  )
                                : active
                                ? NowPlayingBadge(
                                    active: active,
                                    playing: player.isPlaying,
                                    color: activeColor,
                                    size: 14,
                                  )
                                : Text(
                                    index.toString().padLeft(2, '0'),
                                    style: TextStyle(
                                      color: colorScheme.onSurfaceVariant
                                          .withValues(alpha: 0.75),
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                      fontFeatures: const [
                                        FontFeature.tabularFigures(),
                                      ],
                                    ),
                                  ),
                          ),
                        ),
                      ),
                      // 歌曲标题列（flex: 4）
                      //
                      // 标题与专辑列不再整列 IgnorePointer：截断提示需要
                      // 接收悬停事件。点击穿透由 _HoverTipText 内部的
                      // MouseRegion(opaque:false)+IgnorePointer 保证，
                      // 音质微标单独 IgnorePointer 透传行级手势。
                      Expanded(
                        flex: 4,
                        child: Padding(
                          padding: const EdgeInsets.only(right: 12),
                          child: Row(
                            children: [
                              Flexible(
                                child: _HoverTipText(
                                  text: song.title,
                                  style: titleStyle,
                                ),
                              ),
                              if (_buildQualityBadge(context, song)
                                  case final badge?) ...[
                                const SizedBox(width: 6),
                                IgnorePointer(child: badge),
                              ],
                            ],
                          ),
                        ),
                      ),
                      // 歌手列（flex: 3）
                      Expanded(
                        flex: 3,
                        child: Padding(
                          padding: const EdgeInsets.only(right: 12),
                          child: _ArtistLinkText(
                            artistName: song.artist.isNotEmpty
                                ? song.artist
                                : '未知艺人',
                            onTap: widget.onViewArtist,
                          ),
                        ),
                      ),
                      // 专辑列（flex: 3）
                      Expanded(
                        flex: 3,
                        child: Padding(
                          padding: const EdgeInsets.only(right: 12),
                          child: _HoverTipText(
                            text: albumText,
                            style: albumStyle,
                          ),
                        ),
                      ),
                      // 时长 / 悬浮操作列（140px）
                      SizedBox(
                        width: 140,
                        child:
                            (!selecting && _hovering && widget.showHoverActions)
                            ? Row(
                                mainAxisAlignment: MainAxisAlignment.end,
                                children: [
                                  _DesktopRowIconButton(
                                    icon: Icons.play_arrow_rounded,
                                    tooltip: '播放',
                                    onTap: widget.onPlay,
                                  ),
                                  const SizedBox(width: 2),
                                  _DesktopRowIconButton(
                                    icon: isLiked
                                        ? Icons.favorite_rounded
                                        : Icons.favorite_border_rounded,
                                    iconColor: isLiked
                                        ? Colors.redAccent
                                        : null,
                                    tooltip: isLiked ? '取消收藏' : '收藏',
                                    onTap: () => auth.toggleLike(song),
                                  ),
                                  const SizedBox(width: 2),
                                  _DesktopRowIconButton(
                                    icon: Icons.playlist_add_rounded,
                                    tooltip: '添加到歌单',
                                    onTap: widget.onAddToPlaylist,
                                  ),
                                  const SizedBox(width: 2),
                                  Builder(
                                    builder: (moreButtonContext) {
                                      return _DesktopRowIconButton(
                                        icon: canDelete
                                            ? Icons.delete_outline_rounded
                                            : Icons.more_horiz_rounded,
                                        tooltip: canDelete ? '从歌单删除' : '更多',
                                        danger: canDelete,
                                        onTap: canDelete
                                            ? widget.onDelete
                                            : () => _invokeMore(
                                                anchorBelow(moreButtonContext),
                                              ),
                                      );
                                    },
                                  ),
                                  const SizedBox(width: 12),
                                ],
                              )
                            : IgnorePointer(
                                child: Align(
                                  alignment: Alignment.centerRight,
                                  child: Padding(
                                    padding: const EdgeInsets.only(right: 16),
                                    child: Text(
                                      formatDuration(song.duration),
                                      style: TextStyle(
                                        color: active
                                            ? activeColor.withValues(alpha: 0.8)
                                            : colorScheme.onSurfaceVariant,
                                        fontSize: 13,
                                        fontWeight: FontWeight.w400,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

/// 截断文本的悬停完整提示。
///
/// 与 [Tooltip] 的区别：
/// 1. 文本未被截断（单行能完整放下）时不显示提示；
/// 2. 命中测试对上层表格行的 InkWell 透明（`MouseRegion.opaque: false`
///    + `IgnorePointer`），行级单击/双击/右键手势不受影响，
///    这是 Tooltip 无法做到的（会吞掉同层 InkWell 的点击）。
class _HoverTipText extends StatefulWidget {
  const _HoverTipText({required this.text, required this.style});

  final String text;
  final TextStyle style;

  @override
  State<_HoverTipText> createState() => _HoverTipTextState();
}

class _HoverTipTextState extends State<_HoverTipText> {
  // 与全局 tooltip 悬停等待时长保持一致（桌面 500ms token）。
  static final Duration _showDelay = AppDesktopTheme.tooltipWaitDuration;

  final _layerLink = LayerLink();
  OverlayEntry? _entry;
  Timer? _timer;

  void _handleEnter() {
    if (!(_isTruncated())) return;
    _timer?.cancel();
    _timer = Timer(_showDelay, _showTip);
  }

  void _handleExit() {
    _timer?.cancel();
    _hideTip();
  }

  /// 按**用户实际字体缩放**单行排版的自然宽度超出实际可用宽度
  /// => 被省略号截断。
  ///
  /// 必须把 `MediaQuery.textScalerOf` 传给 TextPainter，否则
  /// fontScale > 1.0 时测宽偏小，截断文本会被误判为未截断，
  /// 恰好在最需要提示的场景失效。
  bool _isTruncated() {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return false;
    final painter = TextPainter(
      text: TextSpan(text: widget.text, style: widget.style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    return painter.didExceedMaxLines || painter.width > box.size.width + 0.5;
  }

  void _showTip() {
    if (_entry != null || !mounted) return;
    final colorScheme = Theme.of(context).colorScheme;
    final boxTop = (context.findRenderObject() as RenderBox)
        .localToGlobal(Offset.zero)
        .dy;
    // 贴近窗口顶部时改为向下弹出，避免气泡被裁掉。
    final showBelow = boxTop < 90;

    _entry = OverlayEntry(
      builder: (context) => Positioned(
        child: CompositedTransformFollower(
          link: _layerLink,
          showWhenUnlinked: false,
          targetAnchor: showBelow ? Alignment.bottomLeft : Alignment.topLeft,
          followerAnchor: showBelow ? Alignment.topLeft : Alignment.bottomLeft,
          offset: Offset(0, showBelow ? 4 : -6),
          child: IgnorePointer(
            child: Container(
              constraints: const BoxConstraints(maxWidth: 420),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: colorScheme.inverseSurface,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                widget.text,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: colorScheme.onInverseSurface,
                  fontSize: 12,
                  height: 1.35,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    Overlay.of(context, rootOverlay: true).insert(_entry!);
  }

  void _hideTip() {
    _entry?.remove();
    _entry = null;
  }

  @override
  void dispose() {
    _timer?.cancel();
    _hideTip();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      // opaque: false —— 悬停侦测不拦截本层之外的点击命中，
      // 行级 InkWell（Stack 下层）手势保持与纯 Text 时一致。
      opaque: false,
      onEnter: (_) => _handleEnter(),
      onExit: (_) => _handleExit(),
      child: IgnorePointer(
        child: CompositedTransformTarget(
          link: _layerLink,
          child: Text(
            widget.text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: widget.style,
          ),
        ),
      ),
    );
  }
}

/// 歌手链接组件：支持悬停变色与点击跳转歌手主页。
class _ArtistLinkText extends StatefulWidget {
  const _ArtistLinkText({required this.artistName, required this.onTap});

  final String artistName;
  final VoidCallback onTap;

  @override
  State<_ArtistLinkText> createState() => _ArtistLinkTextState();
}

class _ArtistLinkTextState extends State<_ArtistLinkText> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textStyle = TextStyle(
      color: _hovering
          ? colorScheme.primary
          : colorScheme.onSurfaceVariant.withValues(alpha: 0.85),
      fontSize: 13,
      // 与标题列同理：用原生 Regular，避免 w500 合成导致深浅不一。
      fontWeight: FontWeight.w400,
      decoration: _hovering ? TextDecoration.underline : TextDecoration.none,
      decorationColor: colorScheme.primary,
    );

    return Align(
      alignment: Alignment.centerLeft,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovering = true),
        onExit: (_) => setState(() => _hovering = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: Text(
            widget.artistName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: textStyle,
          ),
        ),
      ),
    );
  }
}

/// 桌面端表格行悬浮微型操作图标按钮。
class _DesktopRowIconButton extends StatelessWidget {
  const _DesktopRowIconButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.iconColor,
    this.danger = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final Color? iconColor;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final color = danger
        ? Colors.redAccent
        : (iconColor ?? colorScheme.onSurfaceVariant);

    return Tooltip(
      message: tooltip,
      waitDuration: AppDesktopTheme.tooltipWaitDuration,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: SizedBox.square(
            dimension: 26,
            child: Center(child: Icon(icon, size: 17, color: color)),
          ),
        ),
      ),
    );
  }
}

/// 歌曲音质/属性微标生成。
Widget? _buildQualityBadge(BuildContext context, Song song) {
  final raw = (song.rawTitle ?? '').toUpperCase();
  final title = song.title.toUpperCase();

  String? badgeText;
  Color badgeColor = Colors.deepOrange;

  if (song.isCloudDrive) {
    badgeText = '云盘';
    badgeColor = Colors.amber.shade800;
  } else if (raw.contains('HI-RES') || title.contains('HI-RES')) {
    badgeText = 'Hi-Res';
    badgeColor = const Color(0xFFE5A000);
  } else if (raw.contains('SQ') ||
      title.contains('SQ') ||
      raw.contains('FLAC') ||
      raw.contains('无损')) {
    badgeText = 'SQ';
    badgeColor = Colors.deepOrange;
  } else if (raw.contains('VIP') || title.contains('VIP')) {
    badgeText = 'VIP';
    badgeColor = Colors.redAccent;
  }

  if (badgeText == null) return null;

  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(3),
      border: Border.all(color: badgeColor.withValues(alpha: 0.8), width: 1),
    ),
    child: Text(
      badgeText,
      style: TextStyle(
        fontSize: 9.5,
        fontWeight: FontWeight.w700,
        color: badgeColor,
        height: 1.1,
      ),
    ),
  );
}
