import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../controllers/player_controller.dart';
import 'app_dialog.dart';

Future<void> showAudioEffectsSheet({
  required BuildContext context,
  required PlayerController player,
}) {
  return Navigator.of(context).push<void>(
    MaterialPageRoute(builder: (_) => AudioEffectsPage(player: player)),
  );
}

class AudioEffectsPage extends StatefulWidget {
  const AudioEffectsPage({super.key, required this.player});

  final PlayerController player;

  @override
  State<AudioEffectsPage> createState() => _AudioEffectsPageState();
}

class _AudioEffectsPageState extends State<AudioEffectsPage> {
  var _tabIndex = 0;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final player = widget.player;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: colorScheme.brightness == Brightness.dark
            ? Brightness.light
            : Brightness.dark,
        statusBarBrightness: colorScheme.brightness == Brightness.dark
            ? Brightness.dark
            : Brightness.light,
      ),
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            tooltip: '关闭',
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close_rounded),
          ),
          title: const Text('自定义音效'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('保存'),
            ),
            const SizedBox(width: 8),
          ],
        ),
        body: AnimatedBuilder(
          animation: player,
          builder: (context, _) {
            if (!player.isAudioEffectsSupported) {
              return _UnsupportedView(colorScheme: colorScheme);
            }

            return Column(
              children: [
                _EffectTabs(index: _tabIndex, onChanged: _setTab),
                Expanded(
                  child: _tabIndex == 0
                      ? _EqualizerPanel(player: player)
                      : _EnhancePanel(player: player),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  void _setTab(int value) {
    setState(() => _tabIndex = value);
  }
}

/// 顶部胶囊分段切换（均衡器/增强）：44 高整圆角胶囊，选中项为悬浮白丸 +
/// 主题色字，与搜索胶囊/药丸按钮同语言。此前 86 高大字标题 + 圆点指示
/// 在移动端显大显旧。
class _EffectTabs extends StatelessWidget {
  const _EffectTabs({required this.index, required this.onChanged});

  final int index;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final labels = ['均衡器', '增强'];
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
      child: Container(
        height: 44,
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: isDark
              ? colorScheme.surfaceContainerHighest
              : const Color(0xFFF1F2F5),
          borderRadius: BorderRadius.circular(22),
        ),
        child: Row(
          children: [
            for (final entry in labels.indexed)
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => onChanged(entry.$1),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeOut,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: entry.$1 == index
                          ? (isDark
                                ? colorScheme.surfaceContainerLowest
                                : Colors.white)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(19),
                      boxShadow: entry.$1 == index
                          ? [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.08),
                                blurRadius: 6,
                                offset: const Offset(0, 2),
                              ),
                            ]
                          : null,
                    ),
                    child: Text(
                      entry.$2,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: entry.$1 == index
                            ? colorScheme.primary
                            : colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _EqualizerPanel extends StatelessWidget {
  const _EqualizerPanel({required this.player});

  final PlayerController player;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final config = player.equalizerConfig;
    final minDb = config.minMillibels / 100;
    final maxDb = config.maxMillibels / 100;

    return Column(
      children: [
        SwitchListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 20),
          title: const Text('启用均衡器'),
          subtitle: Text(
            player.equalizerEnabled ? player.equalizerPresetName : '关闭',
          ),
          value: player.equalizerEnabled,
          onChanged: player.setEqualizerEnabled,
        ),
        const SizedBox(height: 4),
        SizedBox(
          height: 64,
          child: CustomPaint(
            painter: _EqualizerCurvePainter(
              colorScheme: colorScheme,
              levels: player.equalizerLevels,
              min: config.minMillibels,
              max: config.maxMillibels,
            ),
            child: const SizedBox.expand(),
          ),
        ),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: 56,
                child: Padding(
                  padding: const EdgeInsets.only(top: 26, bottom: 44),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        '+${maxDb.round()}dB',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                      Text(
                        '0dB',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                      Text(
                        '${minDb.round()}dB',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.fromLTRB(4, 4, 22, 18),
                  child: Row(
                    children: [
                      for (
                        var index = 0;
                        index < config.bands.length &&
                            index < player.equalizerLevels.length;
                        index++
                      )
                        _EqualizerBandSlider(
                          label: _frequencyLabel(config.bands[index].centerHz),
                          value: player.equalizerLevels[index],
                          min: config.minMillibels,
                          max: config.maxMillibels,
                          enabled: player.equalizerEnabled,
                          onChanged: (value) => player.setEqualizerBandLevel(
                            index,
                            value,
                            persist: false,
                          ),
                          onChangeEnd: (value) =>
                              player.setEqualizerBandLevel(index, value),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
          // 与确认弹窗同语言：左浅底重置 + 右渐变预设（46 高整圆角药丸）。
          child: AppDialogPillActions(
            cancelText: '重置',
            confirmText: '预设',
            onCancel: player.resetEqualizer,
            onConfirm: () => _showPresetPicker(context),
          ),
        ),
      ],
    );
  }

  Future<void> _showPresetPicker(BuildContext context) async {
    final preset = await showModalBottomSheet<AudioEffectPreset>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        return Material(
          color: Theme.of(sheetContext).colorScheme.surface,
          child: SafeArea(
            top: false,
            child: ListView.separated(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
              itemCount: PlayerController.equalizerPresets.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final preset = PlayerController.equalizerPresets[index];
                return ListTile(
                  leading: const Icon(Icons.tune_rounded),
                  title: Text(preset.name),
                  trailing: player.equalizerPresetName == preset.name
                      ? Icon(
                          Icons.check_rounded,
                          color: Theme.of(context).colorScheme.primary,
                        )
                      : null,
                  onTap: () => Navigator.of(sheetContext).pop(preset),
                );
              },
            ),
          ),
        );
      },
    );
    if (preset != null) {
      await player.applyEqualizerPreset(preset);
    }
  }
}

class _EqualizerBandSlider extends StatelessWidget {
  const _EqualizerBandSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.enabled,
    required this.onChanged,
    required this.onChangeEnd,
  });

  final String label;
  final int value;
  final int min;
  final int max;
  final bool enabled;
  final ValueChanged<int> onChanged;
  final ValueChanged<int> onChangeEnd;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final dbValue = value / 100;
    return SizedBox(
      width: 64,
      child: Column(
        children: [
          SizedBox(
            height: 24,
            child: Text(
              dbValue == 0 ? '0' : dbValue.toStringAsFixed(1),
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: enabled
                    ? colorScheme.onSurface
                    : colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Expanded(
            child: RotatedBox(
              quarterTurns: -1,
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 4,
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 10,
                    disabledThumbRadius: 10,
                  ),
                  overlayShape: const RoundSliderOverlayShape(
                    overlayRadius: 18,
                  ),
                  activeTrackColor: colorScheme.primary,
                  inactiveTrackColor: colorScheme.outlineVariant,
                  thumbColor: enabled
                      ? colorScheme.primary
                      : colorScheme.outlineVariant,
                ),
                child: Slider(
                  value: value.toDouble(),
                  min: min.toDouble(),
                  max: max.toDouble(),
                  onChanged: enabled ? (next) => onChanged(next.round()) : null,
                  onChangeEnd: enabled
                      ? (next) => onChangeEnd(next.round())
                      : null,
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            label,
            maxLines: 1,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: enabled
                  ? colorScheme.onSurfaceVariant
                  : colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _EnhancePanel extends StatelessWidget {
  const _EnhancePanel({required this.player});

  final PlayerController player;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final bassPercent = (player.bassBoostStrength * 100).round();

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          secondary: Icon(Icons.speaker_rounded, color: colorScheme.primary),
          title: const Text('低音增强'),
          subtitle: Text(player.bassBoostEnabled ? 'Bass $bassPercent%' : '关闭'),
          value: player.bassBoostEnabled,
          onChanged: player.setBassBoostEnabled,
        ),
        const SizedBox(height: 18),
        Row(
          children: [
            const Text('Bass'),
            Expanded(
              child: Slider(
                value: player.bassBoostStrength,
                onChanged: player.bassBoostEnabled
                    ? (value) =>
                          player.setBassBoostStrength(value, persist: false)
                    : null,
                onChangeEnd: player.bassBoostEnabled
                    ? player.setBassBoostStrength
                    : null,
              ),
            ),
            SizedBox(
              width: 44,
              child: Text(
                '$bassPercent%',
                textAlign: TextAlign.end,
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w800),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _EqualizerCurvePainter extends CustomPainter {
  const _EqualizerCurvePainter({
    required this.colorScheme,
    required this.levels,
    required this.min,
    required this.max,
  });

  final ColorScheme colorScheme;
  final List<int> levels;
  final int min;
  final int max;

  @override
  void paint(Canvas canvas, Size size) {
    final gridPaint = Paint()
      ..color = colorScheme.outlineVariant.withValues(alpha: .56)
      ..strokeWidth = 1;
    for (var i = 1; i < 4; i++) {
      final y = size.height * i / 4;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    final zeroY = _levelToY(0, size.height);
    final zeroPaint = Paint()
      ..color = colorScheme.primary.withValues(alpha: .62)
      ..strokeWidth = 2;
    canvas.drawLine(Offset(0, zeroY), Offset(size.width, zeroY), zeroPaint);

    if (levels.isEmpty) {
      return;
    }

    final linePaint = Paint()
      ..color = colorScheme.primary
      ..strokeWidth = 2.4
      ..style = PaintingStyle.stroke;
    final path = Path();
    for (var index = 0; index < levels.length; index++) {
      final x = levels.length == 1
          ? size.width / 2
          : size.width * index / (levels.length - 1);
      final y = _levelToY(levels[index], size.height);
      if (index == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(path, linePaint);
  }

  double _levelToY(int level, double height) {
    final span = (max - min).abs();
    if (span == 0) {
      return height / 2;
    }
    final normalized = ((level - min) / span).clamp(0.0, 1.0);
    return height * (1 - normalized);
  }

  @override
  bool shouldRepaint(covariant _EqualizerCurvePainter oldDelegate) {
    return oldDelegate.levels != levels ||
        oldDelegate.min != min ||
        oldDelegate.max != max ||
        oldDelegate.colorScheme != colorScheme;
  }
}

class _UnsupportedView extends StatelessWidget {
  const _UnsupportedView({required this.colorScheme});

  final ColorScheme colorScheme;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.info_outline_rounded,
              size: 42,
              color: colorScheme.primary,
            ),
            const SizedBox(height: 14),
            Text(
              '当前平台暂不支持音效调节',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 8),
            Text(
              'Android 设备播放时可使用多段均衡器、预设和低音增强。',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _frequencyLabel(int hz) {
  if (hz >= 1000) {
    final khz = hz / 1000;
    return khz == khz.roundToDouble()
        ? '${khz.round()}k'
        : '${khz.toStringAsFixed(1)}k';
  }
  return '$hz';
}
