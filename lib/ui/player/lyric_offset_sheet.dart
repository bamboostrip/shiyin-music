/// 「调整歌词进度」的共享 UI（移动端底部弹层 + PC 锚定弹层 + 共用步进控件）。
///
/// 设计见 docs/superpowers/specs/2026-09-21-lyric-progress-offset-design.md：
/// 偏移语义为「正 = 歌词提前」，步进为 `− / + 0.5 秒`，偏移按歌曲持久化在
/// PlayerController。
///
/// 视觉走酷狗「调整歌词进度」式的极简三键：居中标题 + 一行三枚白底圆角方钮
/// （`− 0.5 秒` / `重置` / `+ 0.5 秒`，标签在钮下），无大读数、无说明长文；
/// 仅在**已调偏移**时在标题下亮一行短状态（`+0.5 秒 · 已为本首歌记忆`）。
///
/// 入口：移动端播放页「详情」弹层与长按歌词行；PC 端封面开关列 `调` 按钮、
/// 歌词列表右键、桌面歌词悬浮窗快捷菜单。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../controllers/player_controller.dart';
import '../../controllers/player_logic.dart';
import '../../models/music_models.dart';
import '../form_factor.dart';
import '../widgets/desktop_anchored_menu.dart';

/// 打开移动端「调整歌词进度」底部弹层（详情弹层入口 / 长按歌词行）。
///
/// 桌面形态走居中小窗（与倍速 / 定时面板同一形态），移动端走标准底部弹层。
Future<void> showLyricOffsetSheet(
  BuildContext context, {
  required PlayerController player,
  Song? song,
}) {
  if (isDesktopFormFactor) {
    return showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return Dialog(
          backgroundColor: Theme.of(dialogContext).colorScheme.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: _LyricOffsetSheet(
              player: player,
              song: song,
              inDialog: true,
            ),
          ),
        );
      },
    );
  }
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    // 与歌曲详情抽屉同一语言：浅蓝灰底 + 白色悬浮钮 + 24 顶圆角。
    backgroundColor: Theme.of(context).colorScheme.surfaceContainer,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (sheetContext) =>
        _LyricOffsetSheet(player: player, song: song, inDialog: false),
  );
}

/// 打开 PC 端「歌词进度」锚定弹层（封面开关列 / 歌词列表右键）。
Future<void> showLyricOffsetMenu(
  BuildContext context, {
  required PlayerController player,
  required Offset anchor,
}) {
  return showDesktopAnchoredMenu<void>(
    context: context,
    anchor: anchor,
    builder: (_) => DesktopPopupMenuPanel(
      title: '歌词进度',
      width: 264,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 6, 14, 8),
          child: LyricOffsetControl(player: player, compact: true),
        ),
      ],
    ),
  );
}

/// 歌词进度步进控件：一行三枚圆角方钮（`− 0.5 秒` / `重置` / `+ 0.5 秒`，
/// 标签在钮下）+ 仅在已调偏移时出现的短状态行。
///
/// 自监听 [player]：点按后无需父级 setState，状态行与重置可用态即时刷新。
/// `− / +` 支持**长按连调**（首击后每 130ms 一步），20 秒的大偏移不必点四十下。
class LyricOffsetControl extends StatelessWidget {
  const LyricOffsetControl({super.key, required this.player, this.compact = false});

  final PlayerController player;

  /// 紧凑档（PC 锚定弹层）：方钮 52、字号收一档；移动端弹层用大档。
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return AnimatedBuilder(
      animation: player,
      builder: (context, _) {
        final offset = player.lyricOffset;
        final hasOffset = offset != Duration.zero;
        // 移动端 48 钮 + spaceBetween 顶满整排：钮小缝大，对齐参考稿。
        final buttonSize = compact ? 52.0 : 48.0;

        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 状态行：无偏移时占位透明（maintainSize），面板高度恒定——
            // PC 锚定弹层只在打开瞬间量一次尺寸，内容长高会被固定几何
            // 裁成可滚区域（首次点 ± 后底部标签被挤出首屏）。
            Visibility(
              visible: hasOffset,
              maintainSize: true,
              maintainAnimation: true,
              maintainState: true,
              child: Padding(
                padding: EdgeInsets.only(bottom: compact ? 10 : 14),
                child: Text(
                  '${PlayerLyricOffsetLogic.formatSigned(offset)} · 已为本首歌记忆',
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.bodyMedium?.copyWith(
                    color: colorScheme.primary,
                    fontWeight: FontWeight.w700,
                    fontSize: compact ? 12 : 13.5,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ),
            Align(
              alignment: Alignment.center,
              // 移动端顶满整排 + spaceBetween：三钮分别贴左/中/右，
              // 缝直接撑开（参考稿就是这种松散排布）；PC 小窗保持限宽居中。
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: compact ? 240 : double.infinity,
                ),
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: compact ? 0 : 12),
                  child: Row(
                    mainAxisAlignment: compact
                        ? MainAxisAlignment.spaceEvenly
                        : MainAxisAlignment.spaceBetween,
                    children: [
                    _SquareActionButton(
                      icon: Icons.remove_rounded,
                      label: '0.5 秒',
                      tooltip: '歌词延后 0.5 秒',
                      size: buttonSize,
                      compact: compact,
                      repeatable: true,
                      onPressed: () => unawaited(
                        player.adjustLyricOffset(-kLyricOffsetStep),
                      ),
                    ),
                    _SquareActionButton(
                      // 重置语义用回环箭头（restart）：之前 swap_horiz 读起来像
                      // “交换/切换”，和参考稿的重置图标也不一致。
                      icon: Icons.restart_alt_rounded,
                      label: '重置',
                      tooltip: '恢复原始进度',
                      size: buttonSize,
                      compact: compact,
                      enabled: hasOffset,
                      onPressed: () => unawaited(player.resetLyricOffset()),
                    ),
                    _SquareActionButton(
                      icon: Icons.add_rounded,
                      label: '0.5 秒',
                      tooltip: '歌词提前 0.5 秒',
                      size: buttonSize,
                      compact: compact,
                      repeatable: true,
                      onPressed: () => unawaited(
                        player.adjustLyricOffset(kLyricOffsetStep),
                      ),
                    ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 极简圆角方钮（白底 + 柔和投影，标签在下），对齐酷狗面板的三键。
///
/// [repeatable] 的 `− / +` 走长按连调：按下先走一次点击，持续按住 130ms 一步；
/// 中间的 `重置` 不连调，且无偏移时整体置灰不可点。
class _SquareActionButton extends StatefulWidget {
  const _SquareActionButton({
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.size,
    required this.compact,
    required this.onPressed,
    this.enabled = true,
    this.repeatable = false,
  });

  final IconData icon;
  final String label;
  final String tooltip;
  final double size;
  final bool compact;
  final bool enabled;
  final bool repeatable;
  final VoidCallback onPressed;

  @override
  State<_SquareActionButton> createState() => _SquareActionButtonState();
}

class _SquareActionButtonState extends State<_SquareActionButton> {
  static const _repeatInterval = Duration(milliseconds: 130);

  Timer? _repeat;
  bool _pressed = false;
  bool _hovering = false;

  @override
  void dispose() {
    _repeat?.cancel();
    super.dispose();
  }

  void _cancelRepeat() {
    _repeat?.cancel();
    _repeat = null;
  }

  void _startRepeat() {
    _cancelRepeat();
    _repeat = Timer.periodic(_repeatInterval, (_) => widget.onPressed());
  }

  /// 长按结束/取消后收敛按压高亮并停掉连调：长按路径不会走 onTapUp，
  /// 不在这里复位的话按钮会一直亮着、timer 也会一直在后台累加偏移。
  void _endPress() {
    _cancelRepeat();
    if (_pressed) {
      setState(() => _pressed = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    // 浅色：白底 + 柔和投影（参考稿的白卡）；深色：抬高一档的容器色 +
    // 极淡描边，保证在同色弹层上仍然“浮”得起来。
    final Color background = isDark
        ? colorScheme.surfaceContainerHigh
        : colorScheme.surface;
    final Color cardBorder = isDark
        ? Colors.white.withValues(alpha: .07)
        : Colors.transparent;
    final shadow = [
      BoxShadow(
        color: Colors.black.withValues(alpha: isDark ? .35 : .10),
        blurRadius: 14,
        offset: const Offset(0, 4),
      ),
    ];

    final Color fill;
    final Color iconColor;
    if (!widget.enabled) {
      fill = background;
      iconColor = colorScheme.onSurface;
    } else if (_pressed) {
      fill = Color.alphaBlend(
        colorScheme.primary.withValues(alpha: .18),
        background,
      );
      iconColor = colorScheme.primary;
    } else if (_hovering) {
      fill = Color.alphaBlend(
        colorScheme.primary.withValues(alpha: .07),
        background,
      );
      iconColor = colorScheme.onSurface;
    } else {
      fill = background;
      iconColor = colorScheme.onSurface;
    }

    final radius = widget.size * (widget.compact ? .28 : .26);

    return AnimatedOpacity(
      duration: const Duration(milliseconds: 140),
      opacity: widget.enabled ? 1 : .38,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Tooltip(
            message: widget.tooltip,
            child: MouseRegion(
              cursor: widget.enabled
                  ? SystemMouseCursors.click
                  : MouseCursor.defer,
              onEnter: (_) {
                if (widget.enabled) setState(() => _hovering = true);
              },
              onExit: (_) {
                if (_hovering) setState(() => _hovering = false);
              },
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: widget.enabled
                    ? (_) => setState(() => _pressed = true)
                    : null,
                onTapUp: widget.enabled
                    ? (_) => setState(() => _pressed = false)
                    : null,
                onTapCancel: widget.enabled
                    ? () => setState(() => _pressed = false)
                    : null,
                onTap: widget.enabled ? widget.onPressed : null,
                onLongPressStart: widget.enabled && widget.repeatable
                    ? (_) {
                        widget.onPressed();
                        _startRepeat();
                      }
                    : null,
                onLongPressEnd: widget.enabled && widget.repeatable
                    ? (_) => _endPress()
                    : null,
                onLongPressCancel: widget.enabled && widget.repeatable
                    ? _endPress
                    : null,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 140),
                  width: widget.size,
                  height: widget.size,
                  decoration: BoxDecoration(
                    color: fill,
                    borderRadius: BorderRadius.circular(radius),
                    border: Border.all(color: cardBorder),
                    boxShadow: shadow,
                  ),
                  alignment: Alignment.center,
                  child: Icon(
                    widget.icon,
                    size: widget.compact ? 22 : 21,
                    color: iconColor,
                  ),
                ),
              ),
            ),
          ),
          SizedBox(height: widget.compact ? 6 : 8),
          // FittedBox 兜底：系统字体放大时标签缩放而不是溢出方钮。
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              widget.label,
              maxLines: 1,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
                fontSize: widget.compact ? 11 : 12,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 移动端底部弹层 / 桌面居中小窗：居中标题 + 歌曲副标题 + 三键控件。
///
/// 骨架对齐参考稿：无标题前缀图标、无大读数、无说明长文 —— 标题、一行三键、
/// 标签，仅已调偏移时多一行短状态（在 [LyricOffsetControl] 内）。
class _LyricOffsetSheet extends StatelessWidget {
  const _LyricOffsetSheet({
    required this.player,
    required this.inDialog,
    this.song,
  });

  final PlayerController player;
  final bool inDialog;
  final Song? song;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    // 副标题必须跟按钮的实际作用对象（实时 currentSong）一致：
    // 面板开着时可能自动切歌，入口快照 song 会过期，而按钮经
    // adjustLyricOffset 永远写到 currentSong 的 hash 上。
    final content = AnimatedBuilder(
      animation: player,
      builder: (context, _) {
        final target = player.currentSong ?? song;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '调整歌词进度',
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 4),
            Text(
              target == null || target.artist.isEmpty
                  ? '校准结果按歌曲单独记忆'
                  : '${target.artist} · ${target.title}',
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
                fontSize: 13,
                height: 1.2,
              ),
            ),
            const SizedBox(height: 20),
            LyricOffsetControl(player: player),
          ],
        );
      },
    );

    if (inDialog) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(24, 22, 24, 20),
        child: SingleChildScrollView(child: content),
      );
    }
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
        child: SingleChildScrollView(child: content),
      ),
    );
  }
}
