import 'dart:async';

import 'package:flutter/material.dart';

import '../../controllers/player_controller.dart';

Future<void> showSleepTimerSheet({
  required BuildContext context,
  required PlayerController player,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    builder: (context) => _SleepTimerSheet(player: player),
  );
}

class _SleepTimerSheet extends StatefulWidget {
  const _SleepTimerSheet({required this.player});

  final PlayerController player;

  @override
  State<_SleepTimerSheet> createState() => _SleepTimerSheetState();
}

class _SleepTimerSheetState extends State<_SleepTimerSheet> {
  bool _finishSong = false;

  @override
  void initState() {
    super.initState();
    widget.player.addListener(_onPlayerUpdate);
    _finishSong = widget.player.isSleepFinishCurrentSong || widget.player.sleepFinishCurrentSongOption;
  }

  @override
  void dispose() {
    widget.player.removeListener(_onPlayerUpdate);
    super.dispose();
  }

  void _onPlayerUpdate() {
    if (mounted) {
      setState(() {
        _finishSong = widget.player.isSleepFinishCurrentSong || widget.player.sleepFinishCurrentSongOption;
      });
    }
  }

  void _setTimer(Duration duration) {
    if (_finishSong) {
      widget.player.setSleepTimerFinishSong(duration);
    } else {
      widget.player.setSleepTimer(duration);
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final player = widget.player;
    final isActive = player.isSleepTimerActive || player.isSleepFinishCurrentSong;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.bedtime_rounded, color: colorScheme.primary),
                const SizedBox(width: 10),
                Text(
                  '定时播放',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const Spacer(),
                if (isActive)
                  TextButton(
                    onPressed: () {
                      player.cancelSleepTimer();
                      Navigator.of(context).pop();
                    },
                    child: const Text('关闭定时'),
                  ),
              ],
            ),
            if (isActive) ...[
              const SizedBox(height: 8),
              _ActiveTimerDisplay(player: player),
            ],
            const SizedBox(height: 16),
            // Finish song toggle
            Material(
              color: colorScheme.surfaceContainer,
              borderRadius: BorderRadius.circular(12),
              clipBehavior: Clip.antiAlias,
              child: SwitchListTile(
                value: _finishSong,
                onChanged: (v) {
                  setState(() => _finishSong = v);
                  widget.player.updateSleepTimerOption(v);
                },
                title: const Text('播完当前歌曲再停止'),
                subtitle: const Text('定时结束后，等当前歌曲播放完毕再暂停'),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 2,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
            const SizedBox(height: 16),
            // Time presets
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                _TimerChip(
                  label: '15 分钟',
                  onTap: () => _setTimer(const Duration(minutes: 15)),
                ),
                _TimerChip(
                  label: '30 分钟',
                  onTap: () => _setTimer(const Duration(minutes: 30)),
                ),
                _TimerChip(
                  label: '45 分钟',
                  onTap: () => _setTimer(const Duration(minutes: 45)),
                ),
                _TimerChip(
                  label: '60 分钟',
                  onTap: () => _setTimer(const Duration(minutes: 60)),
                ),
                _TimerChip(
                  label: '90 分钟',
                  onTap: () => _setTimer(const Duration(minutes: 90)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ActiveTimerDisplay extends StatelessWidget {
  const _ActiveTimerDisplay({required this.player});

  final PlayerController player;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final remaining = player.sleepTimerRemaining;

    String text;
    if (player.isSleepFinishCurrentSong) {
      if (remaining != null && remaining > Duration.zero) {
        final m = remaining.inMinutes;
        final s = remaining.inSeconds.remainder(60);
        text = '播完歌曲再停止  ${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
      } else {
        text = '播完当前歌曲后停止';
      }
    } else if (remaining != null && remaining > Duration.zero) {
      final m = remaining.inMinutes;
      final s = remaining.inSeconds.remainder(60);
      text = '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    } else {
      text = '已关闭';
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
      decoration: BoxDecoration(
        color: colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.timer_outlined, size: 18, color: colorScheme.onPrimaryContainer),
          const SizedBox(width: 8),
          Text(
            text,
            style: TextStyle(
              color: colorScheme.onPrimaryContainer,
              fontWeight: FontWeight.w700,
              fontSize: 14,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

class _TimerChip extends StatelessWidget {
  const _TimerChip({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(10),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          child: Text(
            label,
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: colorScheme.onSurface,
            ),
          ),
        ),
      ),
    );
  }
}
