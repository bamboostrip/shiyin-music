import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../controllers/player_controller.dart';
import '../../models/music_models.dart';
import '../form_factor.dart';
import 'desktop_lyric_list.dart';
import 'karaoke_painter.dart';
import 'lyric_bottom_bar.dart';
import 'lyric_display_mode.dart';
import 'mobile_lyric_list.dart';
import 'player_controls.dart';

class LyricPlayerPage extends StatefulWidget {
  const LyricPlayerPage({
    super.key,
    required this.player,
    required this.song,
    required this.isPageVisible,
  });

  final PlayerController player;
  final Song song;
  final bool isPageVisible;

  @override
  State<LyricPlayerPage> createState() => _LyricPlayerPageState();
}

class _LyricPlayerPageState extends State<LyricPlayerPage>
    with AutomaticKeepAliveClientMixin {
  static const _lyricScaleKey = 'settings.lyric_scale';
  static const _showTranslationKey = 'settings.lyric_show_translation';
  static const _showRomanizationKey = 'settings.lyric_show_romanization';

  double _lyricScale = 1.0;
  bool _showTranslation = true;
  bool _showRomanization = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
    // 兜底：非点歌路径进页时歌词可能为空，补拉一次。
    unawaited(widget.player.ensureLyricsLoaded());
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _lyricScale = prefs.getDouble(_lyricScaleKey) ?? 1.0;
        _showTranslation = prefs.getBool(_showTranslationKey) ?? true;
        _showRomanization = prefs.getBool(_showRomanizationKey) ?? false;
      });
    }
  }

  Future<void> _setLyricScale(double scale) async {
    final clamped = scale.clamp(0.7, 1.5);
    setState(() => _lyricScale = clamped);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_lyricScaleKey, clamped);
  }

  Future<void> _setShowTranslation(bool show) async {
    setState(() => _showTranslation = show);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_showTranslationKey, show);
  }

  Future<void> _setShowRomanization(bool show) async {
    setState(() => _showRomanization = show);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_showRomanizationKey, show);
  }

  @override
  bool get wantKeepAlive => true;

  @override
  void didUpdateWidget(covariant LyricPlayerPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 同一首歌但歌词为空（之前请求失败）：切回来时再补拉一次。
    if (oldWidget.song.hash == widget.song.hash &&
        widget.player.lyrics.isEmpty) {
      unawaited(widget.player.ensureLyricsLoaded());
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final lyrics = widget.player.lyrics;
    final hasTranslation = lyrics.any(
      (l) => l.translation != null && l.translation!.isNotEmpty,
    );
    final hasRomanization = lyrics.any(
      (l) => l.romanization != null && l.romanization!.isNotEmpty,
    );

    if (lyrics.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              widget.player.isPreparing ? '正在准备音乐...' : '暂无歌词',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w800,
              ),
            ),
            if (!widget.player.isPreparing)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: GlassIconButton(
                  tooltip: '重新加载歌词',
                  onPressed: () =>
                      unawaited(widget.player.ensureLyricsLoaded()),
                  icon: Icons.refresh_rounded,
                ),
              ),
          ],
        ),
      );
    }

    if (isDesktopFormFactor) {
      return ExcludeSemantics(
        excluding: isDesktopPlatform,
        child: DesktopLyricList(
          player: widget.player,
          songHash: widget.song.hash,
          lyrics: lyrics,
          activeIndex: widget.player.activeLyricIndex,
          displayMode: _showTranslation
              ? LyricDisplayMode.lyricsWithTranslation
              : (_showRomanization
                    ? LyricDisplayMode.lyricsWithRomanization
                    : LyricDisplayMode.lyricsOnly),
          lyricScale: _lyricScale,
        ),
      );
    }

    return Column(
      children: [
        Expanded(
          child: ExcludeSemantics(
            excluding: isDesktopPlatform,
            child: MobileLyricList(
              player: widget.player,
              songHash: widget.song.hash,
              lyrics: lyrics,
              activeIndex: widget.player.activeLyricIndex,
              showTranslation: _showTranslation,
              showRomanization: _showRomanization,
              lyricScale: _lyricScale,
              isPageVisible: widget.isPageVisible,
            ),
          ),
        ),
        LyricBottomBar(
          player: widget.player,
          song: widget.song,
          showTranslation: _showTranslation,
          showRomanization: _showRomanization,
          hasTranslation: hasTranslation,
          hasRomanization: hasRomanization,
          lyricScale: _lyricScale,
          onToggleTranslation: _setShowTranslation,
          onToggleRomanization: _setShowRomanization,
          onLyricScaleChanged: _setLyricScale,
        ),
      ],
    );
  }
}

/// 兼容性门面组件：桌面端委托至 [DesktopLyricList]，移动端委托至 [MobileLyricList]
class LyricViewport extends StatelessWidget {
  const LyricViewport({
    super.key,
    required this.player,
    required this.songHash,
    required this.lyrics,
    required this.activeIndex,
    required this.isPreparing,
    required this.displayMode,
    required this.isPageVisible,
    required this.lyricScale,
  });

  final PlayerController player;
  final String songHash;
  final List<LyricLine> lyrics;
  final int activeIndex;
  final bool isPreparing;
  final LyricDisplayMode displayMode;
  final bool isPageVisible;
  final double lyricScale;

  @override
  Widget build(BuildContext context) {
    if (isDesktopFormFactor) {
      return DesktopLyricList(
        player: player,
        songHash: songHash,
        lyrics: lyrics,
        activeIndex: activeIndex,
        displayMode: displayMode,
        lyricScale: lyricScale,
      );
    }
    return MobileLyricList(
      player: player,
      songHash: songHash,
      lyrics: lyrics,
      activeIndex: activeIndex,
      showTranslation: displayMode == LyricDisplayMode.lyricsWithTranslation,
      showRomanization: displayMode == LyricDisplayMode.lyricsWithRomanization,
      lyricScale: lyricScale,
      isPageVisible: isPageVisible,
    );
  }
}

/// 逐字卡拉OK歌词行（有 word 级时间且为当前行时启用 [KaraokeLinePainter]）。
///
/// 有状态缓存 painter：海报页播放中每帧都在更新 [position]，仅位置变化
/// 时走 [KaraokeLinePainter.withPosition] 共享排版结果（不重新 layout），
/// 排版参数（行/样式/颜色/约束）变化时才重建并释放旧 painter 的原生资源。
class LyricText extends StatefulWidget {
  const LyricText({
    super.key,
    required this.line,
    required this.active,
    required this.position,
    this.styleOverride,
    this.textAlign = TextAlign.start,
    this.singleLine = false,
  });

  final LyricLine line;
  final bool active;
  final Duration position;
  final TextStyle? styleOverride;
  final TextAlign textAlign;
  final bool singleLine;

  @override
  State<LyricText> createState() => _LyricTextState();
}

class _LyricTextState extends State<LyricText> {
  KaraokeLinePainter? _painter;

  @override
  void dispose() {
    _painter?.release();
    _painter = null;
    super.dispose();
  }

  KaraokeLinePainter _painterFor({
    required TextStyle style,
    required TextDirection textDirection,
    required TextAlign textAlign,
    required int? maxLines,
    required double maxWidth,
  }) {
    const baseColor = Color.fromRGBO(255, 255, 255, 0.34);
    const activeColor = Colors.white;
    final old = _painter;
    if (old != null &&
        old.line == widget.line &&
        old.style == style &&
        old.baseColor == baseColor &&
        old.activeColor == activeColor &&
        old.textDirection == textDirection &&
        old.textAlign == textAlign &&
        old.maxLines == maxLines &&
        old.maxWidth == maxWidth) {
      // 仅位置变化：复用排版，生成轻量副本驱动重绘。
      if (old.position == widget.position) return old;
      _painter = old.withPosition(widget.position);
      return _painter!;
    }
    old?.release();
    _painter = KaraokeLinePainter(
      line: widget.line,
      position: widget.position,
      style: style,
      baseColor: baseColor,
      activeColor: activeColor,
      textDirection: textDirection,
      textAlign: textAlign,
      maxLines: maxLines,
      maxWidth: maxWidth,
    );
    return _painter!;
  }

  @override
  Widget build(BuildContext context) {
    final style =
        widget.styleOverride ??
        Theme.of(context).textTheme.headlineMedium!.copyWith(
          color: Colors.white,
          fontSize: widget.active ? 34 : 27,
          height: 1.24,
          fontWeight: widget.active ? FontWeight.w900 : FontWeight.w800,
        );

    if (!widget.active || widget.line.words.isEmpty) {
      // 退出卡拉OK态（切行/无逐字时间）：释放缓存的排版资源。
      _painter?.release();
      _painter = null;
      if (widget.singleLine) {
        return Text(
          widget.line.text,
          textAlign: widget.textAlign,
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.visible,
          style: style,
        );
      }
      return Text(widget.line.text, textAlign: widget.textAlign, style: style);
    }

    if (widget.singleLine) {
      final painter = _painterFor(
        style: style,
        textDirection: Directionality.of(context),
        textAlign: widget.textAlign,
        maxLines: 1,
        maxWidth: double.infinity,
      );
      return CustomPaint(
        size: Size(painter.width, painter.height),
        painter: painter,
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final painter = _painterFor(
          style: style,
          textDirection: Directionality.of(context),
          textAlign: widget.textAlign,
          maxLines: null,
          maxWidth: constraints.maxWidth,
        );
        return CustomPaint(
          size: Size(constraints.maxWidth, painter.height),
          painter: painter,
        );
      },
    );
  }
}
