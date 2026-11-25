import 'dart:async';

import 'package:flutter/material.dart';

import '../../controllers/player_controller.dart';
import '../../models/music_models.dart';
import '../../widgets/apple_lyrics/apple_lyrics_view.dart';
import '../../widgets/apple_lyrics/layout/lyric_preferences.dart';
import '../../widgets/apple_lyrics/models/lyric_line.dart' as apple;
import 'lyric_seek_pointer_button.dart';

/// Apple Music 歌词动效适配层（移植自 md3Music，AGPL-3.0，见
/// lib/widgets/apple_lyrics/NOTICE.md）。
///
/// 职责：
/// 1. 时音 [LyricLine]（Duration 基）→ apple_lyrics [apple.LyricLine]（ms 基）；
/// 2. 把时音设置（字号倍率 / 翻译 / 音译）同步进 [LyricPreferences]，
///    动效开关首跑默认值见 [LyricPreferences.seedShiyinDefaults]，
///    之后由「歌词动画」设置页管理；
/// 3. 进度桥：player.lyricPosition（平滑 + 歌词偏移）→ positionListenable，
///    暂停时调整偏移也能即时刷新（监听 player 通知补齐位置流空窗）；
/// 4. 保留原 MobileLyricList 的准星胶囊 UX：拖动时 38% 焦点线 + 时间胶囊。

/// 无时长信息的末行兜底时长。
const int _kFallbackLineDurationMs = 5000;

apple.LyricLine _convertLine(LyricLine line, Duration? nextTime) {
  var durationMs = line.duration?.inMilliseconds;
  if (durationMs == null && nextTime != null) {
    durationMs = nextTime.inMilliseconds - line.time.inMilliseconds;
  }
  if (durationMs == null && line.words.isNotEmpty) {
    final last = line.words.last;
    durationMs =
        last.time.inMilliseconds +
        last.duration.inMilliseconds -
        line.time.inMilliseconds;
  }
  durationMs ??= _kFallbackLineDurationMs;
  if (durationMs < 0) durationMs = 0;
  return apple.LyricLine(
    startTime: line.time.inMilliseconds,
    duration: durationMs,
    text: line.text,
    words: [
      for (final w in line.words)
        apple.LyricWord(
          startTime: w.time.inMilliseconds,
          duration: w.duration.inMilliseconds,
          text: w.text,
        ),
    ],
    translation: line.translation,
    roma: line.romanization,
  );
}

/// 把时音歌词设置同步进 apple_lyrics 偏好单例。
///
/// 模糊 / 辉光 / 锚位等动效参数首跑由 [LyricPreferences.seedShiyinDefaults]
/// 写入默认值，之后完全交给「歌词动画」设置页与预设导入管理，这里不再
/// 强制覆盖（否则用户调的参数每次进歌词页都会被重置）。
///
/// 翻译/音译：apple_lyrics 副行一次只显示一种（displayMode），两者同时开启
/// 时优先翻译（与时音默认观感一致）；副行显示范围对齐时音的「所有行」。
Future<void> syncAppleLyricPreferences({
  required double lyricScale,
  required bool showTranslation,
  required bool showRomanization,
}) async {
  final prefs = LyricPreferences.instance;
  await prefs.seedShiyinDefaults();
  await prefs.setFontSize(
    LyricPreferences.defaultFontSizeForCurrentPlatform * lyricScale,
  );
  await prefs.setShowTranslation(showTranslation || showRomanization);
  await prefs.setDisplayMode(
    showRomanization && !showTranslation
        ? LyricDisplayMode.roma
        : LyricDisplayMode.translation,
  );
}

class ShiyinAppleLyrics extends StatefulWidget {
  const ShiyinAppleLyrics({
    super.key,
    required this.player,
    required this.songHash,
    required this.lyrics,
    required this.showTranslation,
    required this.showRomanization,
    required this.lyricScale,
    required this.isPageVisible,
    this.onLongPressLine,
  });

  final PlayerController player;
  final String songHash;
  final List<LyricLine> lyrics;
  final bool showTranslation;
  final bool showRomanization;
  final double lyricScale;
  final bool isPageVisible;
  final VoidCallback? onLongPressLine;

  @override
  State<ShiyinAppleLyrics> createState() => _ShiyinAppleLyricsState();
}

class _ShiyinAppleLyricsState extends State<ShiyinAppleLyrics> {
  late final ValueNotifier<Duration> _posNotifier;
  List<LyricLine>? _convertedSource;
  List<apple.LyricLine> _converted = const [];
  bool _holding = false;
  int _focusIndex = -1;

  @override
  void initState() {
    super.initState();
    _posNotifier = ValueNotifier<Duration>(widget.player.lyricPosition);
    widget.player.positionListenable.addListener(_syncPosition);
    widget.player.addListener(_syncPosition);
    unawaited(_syncPreferences());
  }

  @override
  void didUpdateWidget(covariant ShiyinAppleLyrics oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.player != widget.player) {
      oldWidget.player.positionListenable.removeListener(_syncPosition);
      oldWidget.player.removeListener(_syncPosition);
      widget.player.positionListenable.addListener(_syncPosition);
      widget.player.addListener(_syncPosition);
      _syncPosition();
    }
    if (oldWidget.songHash != widget.songHash) {
      _holding = false;
      _focusIndex = -1;
      _syncPosition();
    }
    if (oldWidget.lyricScale != widget.lyricScale ||
        oldWidget.showTranslation != widget.showTranslation ||
        oldWidget.showRomanization != widget.showRomanization) {
      unawaited(_syncPreferences());
    }
  }

  @override
  void dispose() {
    widget.player.positionListenable.removeListener(_syncPosition);
    widget.player.removeListener(_syncPosition);
    _posNotifier.dispose();
    super.dispose();
  }

  Future<void> _syncPreferences() => syncAppleLyricPreferences(
    lyricScale: widget.lyricScale,
    showTranslation: widget.showTranslation,
    showRomanization: widget.showRomanization,
  );

  /// 位置流（~200ms）与 player 通知（暂停时偏移调整等）都汇聚到这里。
  void _syncPosition() {
    if (!mounted) return;
    final pos = widget.player.lyricPosition;
    if (pos != _posNotifier.value) {
      _posNotifier.value = pos;
    }
  }

  List<apple.LyricLine> _convertIfNeeded() {
    if (identical(_convertedSource, widget.lyrics)) return _converted;
    _convertedSource = widget.lyrics;
    final lines = widget.lyrics;
    _converted = [
      for (var i = 0; i < lines.length; i++)
        _convertLine(lines[i], i + 1 < lines.length ? lines[i + 1].time : null),
    ];
    return _converted;
  }

  @override
  Widget build(BuildContext context) {
    final lines = _convertIfNeeded();
    // 锚位跟随「歌词动画」页设置：拖动歌词时的准星胶囊与歌词焦点线同位。
    // 外层 RepaintBoundary：歌词层与宿主背景/准星胶囊隔离成独立图层，
    // 歌词每帧重绘不会连带宿主 Stack 一起 raster（对齐 md3 的分层）。
    return RepaintBoundary(
      child: ListenableBuilder(
        listenable: LyricPreferences.instance,
        builder: (context, _) {
          return LayoutBuilder(
            builder: (context, constraints) {
              final targetY =
                  constraints.maxHeight *
                  LyricPreferences.instance.alignPosition;
              final focusedLine =
                  (_holding &&
                      _focusIndex >= 0 &&
                      _focusIndex < widget.lyrics.length)
                  ? widget.lyrics[_focusIndex]
                  : null;
              return TickerMode(
                enabled: widget.isPageVisible,
                child: Stack(
                  children: [
                    AppleLyricsView(
                      lines: lines,
                      currentTimeMs: widget.player.lyricPosition.inMilliseconds,
                      isPlaying: widget.player.isPlaying && widget.isPageVisible,
                      playbackNotReady: widget.player.isPreparing,
                      positionListenable: _posNotifier,
                      forceDarkBackground: true,
                      enableInterludeDots: lines.any((l) => l.words.isNotEmpty),
                      onSeek: (ms) => unawaited(
                        widget.player.seekToAndPlay(Duration(milliseconds: ms)),
                      ),
                      onLongPress: widget.onLongPressLine,
                      onUserScrollingChanged: (holding) {
                        if (!mounted) return;
                        setState(() {
                          _holding = holding;
                          if (!holding) _focusIndex = -1;
                        });
                      },
                      onScrollFocusLineChanged: (index) {
                        if (!mounted || index == _focusIndex) return;
                        setState(() => _focusIndex = index);
                      },
                    ),
                    // 准星参考线与右侧时间胶囊（与原 MobileLyricList 同款视觉）。
                    if (focusedLine != null)
                      Positioned(
                        left: 0,
                        right: 12,
                        top: targetY - 14,
                        height: 28,
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Expanded(
                              child: Container(
                                height: 1,
                                margin: const EdgeInsets.only(right: 10),
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    colors: [
                                      Colors.white.withValues(alpha: 0.0),
                                      Colors.white.withValues(alpha: 0.08),
                                      Colors.white.withValues(alpha: 0.28),
                                      Colors.white.withValues(alpha: 0.14),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                            LyricSeekPointerButton(
                              key: const ValueKey(
                                'mobile_lyric_seek_pointer_button',
                              ),
                              timeText: formatDuration(focusedLine.time),
                              onTap: () {
                                unawaited(
                                  widget.player.seekToAndPlay(focusedLine.time),
                                );
                                setState(() {
                                  _holding = false;
                                  _focusIndex = -1;
                                });
                              },
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}