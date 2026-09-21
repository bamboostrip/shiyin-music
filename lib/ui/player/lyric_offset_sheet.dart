/// 「调整歌词进度」的共享 UI（移动端底部弹层 + PC 锚定弹层 + 共用步进控件）。
///
/// 设计见 docs/superpowers/specs/2026-09-21-lyric-progress-offset-design.md：
/// 偏移语义为「正 = 歌词提前」，步进为 `− 0.5 秒 / + 0.5 秒`
/// （对齐酷狗「调整歌词进度」面板），偏移按歌曲持久化在 PlayerController。
///
/// 视觉与倍速 / 定时 / 音质弹层同一套语言：主题 surface 底 + 主色标题行 +
/// 居中大读数 + 步进键 + `TextButton` 重置，不再自带深色衬底。
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
    backgroundColor: Theme.of(context).colorScheme.surface,
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
          padding: const EdgeInsets.fromLTRB(12, 2, 12, 12),
          child: LyricOffsetControl(player: player, compact: true),
        ),
      ],
    ),
  );
}

/// 歌词进度步进控件：大读数 + `− 0.5 秒 / + 0.5 秒` + `重置` + 状态提示。
///
/// 自监听 [player]：点按后无需父级 setState，读数与重置可用态即时刷新。
/// 步进键支持**长按连调**（首击后每 130ms 一步），20 秒的大偏移不必点四十下。
class LyricOffsetControl extends StatelessWidget {
  const LyricOffsetControl({super.key, required this.player, this.compact = false});

  final PlayerController player;

  /// 紧凑档（PC 锚定弹层）：键高 44、字号收一档；移动端弹层用大档。
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return AnimatedBuilder(
      animation: player,
      builder: (context, _) {
        final offset = player.lyricOffset;
        final hasOffset = offset != Duration.zero;

        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 当前偏移大读数（对齐倍速面板的 headline 读数）。
            Text(
              hasOffset ? _signedLabel(offset) : '无偏移',
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.w900,
                fontFeatures: const [FontFeature.tabularFigures()],
                color: hasOffset ? colorScheme.primary : colorScheme.onSurface,
              ),
            ),
            SizedBox(height: compact ? 2 : 4),
            Text(
              hasOffset
                  ? '${PlayerLyricOffsetLogic.describe(offset)} · 已为本首歌记忆'
                  : '歌词与伴奏对不上时，用下面按钮校准',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
                fontSize: compact ? 11 : 12,
              ),
            ),
            SizedBox(height: compact ? 12 : 16),
            Row(
              children: [
                Expanded(
                  child: _OffsetStepButton(
                    icon: Icons.remove_rounded,
                    label: '0.5 秒',
                    tooltip: '歌词延后 0.5 秒',
                    compact: compact,
                    onPressed: () =>
                        unawaited(player.adjustLyricOffset(-kLyricOffsetStep)),
                  ),
                ),
                SizedBox(width: compact ? 8 : 10),
                Expanded(
                  child: _OffsetStepButton(
                    icon: Icons.add_rounded,
                    label: '0.5 秒',
                    tooltip: '歌词提前 0.5 秒',
                    compact: compact,
                    onPressed: () =>
                        unawaited(player.adjustLyricOffset(kLyricOffsetStep)),
                  ),
                ),
              ],
            ),
            SizedBox(height: compact ? 4 : 8),
            Center(
              child: TextButton.icon(
                onPressed: hasOffset
                    ? () => unawaited(player.resetLyricOffset())
                    : null,
                icon: const Icon(Icons.restart_alt_rounded, size: 18),
                label: const Text('恢复原始进度'),
              ),
            ),
            if (!compact) ...[
              const SizedBox(height: 2),
              Text(
                '「+」歌词提前 · 「−」歌词延后，长按可连续调整',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant.withValues(alpha: .8),
                  fontSize: 11.5,
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

/// 带符号的偏移读数：`+0.5 秒` / `−1 秒`（整数不带小数，非整数保留一位）。
String _signedLabel(Duration value) {
  final sign = value > Duration.zero ? '+' : '−';
  return '$sign${PlayerLyricOffsetLogic.formatSeconds(value)}';
}

/// 步进键：主题 surfaceContainerHighest 底 + InkWell 水波纹（对齐定时预设 chip）。
///
/// 长按连调：按下先走一次点击，持续按住则 130ms 一步。
class _OffsetStepButton extends StatefulWidget {
  const _OffsetStepButton({
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.compact,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final String tooltip;
  final bool compact;
  final VoidCallback onPressed;

  @override
  State<_OffsetStepButton> createState() => _OffsetStepButtonState();
}

class _OffsetStepButtonState extends State<_OffsetStepButton> {
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
    final colorScheme = Theme.of(context).colorScheme;
    final base = colorScheme.surfaceContainerHighest;

    // 手势只走 GestureDetector 一路：InkWell 在当前 Flutter 版没有
    // onLongPressStart/End，用两套会点按触发两次（一次走成 1 秒）。
    final Color background;
    final Color border;
    if (_pressed) {
      background = Color.alphaBlend(
        colorScheme.primary.withValues(alpha: .28),
        base,
      );
      border = colorScheme.primary.withValues(alpha: .8);
    } else if (_hovering) {
      background = Color.alphaBlend(
        colorScheme.primary.withValues(alpha: .12),
        base,
      );
      border = colorScheme.primary.withValues(alpha: .45);
    } else {
      background = base;
      border = Colors.transparent;
    }

    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovering = true),
        onExit: (_) => setState(() => _hovering = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => setState(() => _pressed = true),
          onTapUp: (_) => setState(() => _pressed = false),
          onTapCancel: () => setState(() => _pressed = false),
          onTap: widget.onPressed,
          onLongPressStart: (_) {
            widget.onPressed();
            _startRepeat();
          },
          onLongPressEnd: (_) => _endPress(),
          onLongPressCancel: _endPress,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            padding: EdgeInsets.symmetric(
              vertical: widget.compact ? 10 : 13,
            ),
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(widget.compact ? 10 : 12),
              border: Border.all(color: border, width: 1.2),
            ),
            alignment: Alignment.center,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  widget.icon,
                  size: widget.compact ? 18 : 20,
                  color: colorScheme.onSurface,
                ),
                const SizedBox(width: 6),
                Text(
                  widget.label,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    fontSize: widget.compact ? 13 : 14,
                    fontFeatures: const [FontFeature.tabularFigures()],
                    color: colorScheme.onSurface,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 移动端底部弹层 / 桌面居中小窗：标题行 + 歌曲副标题 + 步进控件。
///
/// 骨架对齐倍速 / 定时弹层（标题行 + 说明 + 内容 + 內边距），不再自带深色底。
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
    final target = song ?? player.currentSong;

    final content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.sync_rounded, color: colorScheme.primary, size: 22),
            const SizedBox(width: 10),
            Text(
              '调整歌词进度',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          target == null || target.artist.isEmpty
              ? '校准结果按歌曲单独记忆'
              : '${target.artist} · ${target.title}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 12),
        Material(
          color: colorScheme.surfaceContainer,
          borderRadius: BorderRadius.circular(16),
          clipBehavior: Clip.antiAlias,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
            child: LyricOffsetControl(player: player),
          ),
        ),
      ],
    );

    if (inDialog) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
        child: SingleChildScrollView(child: content),
      );
    }
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: SingleChildScrollView(child: content),
      ),
    );
  }
}
