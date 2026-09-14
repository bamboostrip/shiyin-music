import 'package:flutter/material.dart';

import '../../controllers/player_controller.dart';
import '../../models/music_models.dart';
import 'player_comment_button.dart';

/// QQ 音乐风格带 `on` / `off` 状态角标的药丸按键。
class LyricTogglePill extends StatelessWidget {
  const LyricTogglePill({
    super.key,
    required this.label,
    required this.isOn,
    required this.onToggle,
    this.tooltip,
  });

  final String label;
  final bool isOn;
  final VoidCallback onToggle;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final effectiveColor = isOn
        ? Colors.white
        : Colors.white.withValues(alpha: 0.38);
    final borderColor = isOn
        ? Colors.white.withValues(alpha: 0.70)
        : Colors.white.withValues(alpha: 0.22);

    final content = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onToggle,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          Container(
            width: 34,
            height: 30,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: borderColor, width: 1.2),
              color: isOn
                  ? Colors.white.withValues(alpha: 0.12)
                  : Colors.transparent,
            ),
            alignment: Alignment.center,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w700,
                color: effectiveColor,
                height: 1,
              ),
            ),
          ),
          Positioned(
            right: -4,
            top: -5,
            child: Text(
              isOn ? 'on' : 'off',
              style: TextStyle(
                fontSize: 8.5,
                fontWeight: FontWeight.w700,
                color: effectiveColor,
                height: 1,
                letterSpacing: -0.2,
              ),
            ),
          ),
        ],
      ),
    );

    if (tooltip != null) {
      return Tooltip(message: tooltip!, child: content);
    }
    return content;
  }
}

/// 歌词字号与排版弹层入口按钮 `[词]`
class _LyricSettingsPill extends StatelessWidget {
  const _LyricSettingsPill({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: '调节歌词字号',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          width: 34,
          height: 30,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.40),
              width: 1.2,
            ),
            color: Colors.transparent,
          ),
          alignment: Alignment.center,
          child: Text(
            '词',
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w700,
              color: Colors.white.withValues(alpha: 0.85),
              height: 1,
            ),
          ),
        ),
      ),
    );
  }
}

/// 歌词页底部圆形播放/暂停按键
class _LyricRoundPlayPauseButton extends StatelessWidget {
  const _LyricRoundPlayPauseButton({required this.player});

  final PlayerController player;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: player,
      builder: (context, _) {
        final isPlaying = player.isPlaying;
        return Material(
          color: Colors.transparent,
          child: InkWell(
            key: const ValueKey('lyric_round_play_pause_button'),
            borderRadius: BorderRadius.circular(20),
            onTap: () => player.togglePlay(),
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.25),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Center(
                child: Icon(
                  isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  size: 24,
                  color: Colors.black,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 歌词页底部 QQ 音乐风格控制栏：
/// - 左侧：评论按钮（自绘气泡 + 实时评论数角标）
/// - 右侧：`[词]` 字号入口、`[译 on/off]`、`[音 on/off]` 及圆形播放/暂停键
class LyricBottomBar extends StatelessWidget {
  const LyricBottomBar({
    super.key,
    required this.player,
    required this.song,
    required this.showTranslation,
    required this.showRomanization,
    required this.hasTranslation,
    required this.hasRomanization,
    required this.lyricScale,
    required this.onToggleTranslation,
    required this.onToggleRomanization,
    required this.onLyricScaleChanged,
    this.onOpenComment,
  });

  final PlayerController player;
  final Song song;
  final bool showTranslation;
  final bool showRomanization;
  final bool hasTranslation;
  final bool hasRomanization;
  final double lyricScale;
  final ValueChanged<bool> onToggleTranslation;
  final ValueChanged<bool> onToggleRomanization;
  final ValueChanged<double> onLyricScaleChanged;
  final ValueChanged<String>? onOpenComment;

  void _showFontSizeSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => _LyricFontSizeSheet(
        initialScale: lyricScale,
        onChanged: onLyricScaleChanged,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // 左侧：评论入口
          PlayerCommentButton(
            player: player,
            song: song,
            iconSize: 22.0,
            iconColor: Colors.white.withValues(alpha: 0.85),
            onOpenComment: onOpenComment,
          ),

          const Spacer(),

          // 右侧：[词] 字号调节
          _LyricSettingsPill(onTap: () => _showFontSizeSheet(context)),
          const SizedBox(width: 14),

          // [译 on/off]
          if (hasTranslation) ...[
            LyricTogglePill(
              label: '译',
              isOn: showTranslation,
              tooltip: '翻译 (${showTranslation ? '已开启' : '已关闭'})',
              onToggle: () => onToggleTranslation(!showTranslation),
            ),
            const SizedBox(width: 14),
          ],

          // [音 on/off]
          if (hasRomanization) ...[
            LyricTogglePill(
              label: '音',
              isOn: showRomanization,
              tooltip: '拼音/音译 (${showRomanization ? '已开启' : '已关闭'})',
              onToggle: () => onToggleRomanization(!showRomanization),
            ),
            const SizedBox(width: 14),
          ],

          // 圆形播放/暂停
          _LyricRoundPlayPauseButton(player: player),
        ],
      ),
    );
  }
}

class _LyricFontSizeSheet extends StatefulWidget {
  const _LyricFontSizeSheet({
    required this.initialScale,
    required this.onChanged,
  });

  final double initialScale;
  final ValueChanged<double> onChanged;

  @override
  State<_LyricFontSizeSheet> createState() => _LyricFontSizeSheetState();
}

class _LyricFontSizeSheetState extends State<_LyricFontSizeSheet> {
  late double _scale;

  @override
  void initState() {
    super.initState();
    _scale = widget.initialScale;
  }

  void _update(double newScale) {
    final clamped = newScale.clamp(0.7, 1.5);
    setState(() => _scale = clamped);
    widget.onChanged(clamped);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Container(
        margin: const EdgeInsets.all(16),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        decoration: BoxDecoration(
          color: const Color(0xFF1E1E24).withValues(alpha: 0.95),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.4),
              blurRadius: 16,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.format_size_rounded,
                  color: Colors.white,
                  size: 20,
                ),
                const SizedBox(width: 8),
                const Text(
                  '歌词字体大小',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () => _update(1.0),
                  child: Text(
                    '恢复默认',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.6),
                      fontSize: 13,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                IconButton(
                  tooltip: '缩小字号',
                  icon: const Icon(Icons.remove_rounded, color: Colors.white),
                  onPressed: _scale > 0.7 ? () => _update(_scale - 0.1) : null,
                ),
                Expanded(
                  child: Slider(
                    value: _scale,
                    min: 0.7,
                    max: 1.5,
                    divisions: 8,
                    label: '${(_scale * 100).round()}%',
                    activeColor: Colors.white,
                    inactiveColor: Colors.white.withValues(alpha: 0.24),
                    onChanged: (val) => _update(val),
                  ),
                ),
                IconButton(
                  tooltip: '放大字号',
                  icon: const Icon(Icons.add_rounded, color: Colors.white),
                  onPressed: _scale < 1.5 ? () => _update(_scale + 0.1) : null,
                ),
              ],
            ),
            Text(
              '${(_scale * 100).round()}%',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.7),
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
