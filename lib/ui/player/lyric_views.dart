import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_lyric/flutter_lyric.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../controllers/player_controller.dart';
import '../../models/music_models.dart';
import '../../services/lyric_converter.dart';
import '../form_factor.dart';
import 'desktop_lyric_list.dart';
import 'karaoke_painter.dart';
import 'lyric_display_mode.dart';
import 'player_controls.dart';

class LyricPlayerPage extends StatefulWidget {
  const LyricPlayerPage({
    super.key,
    required this.player,
    required this.song,
    required this.focusRequest,
    required this.isPageActive,
    required this.isPageVisible,
    required this.isPageTransitioning,
  });

  final PlayerController player;
  final Song song;
  final int focusRequest;
  final bool isPageActive;
  final bool isPageVisible;
  final bool isPageTransitioning;

  @override
  State<LyricPlayerPage> createState() => _LyricPlayerPageState();
}

class _LyricPlayerPageState extends State<LyricPlayerPage>
    with AutomaticKeepAliveClientMixin {
  late LyricDisplayMode _displayMode;

  /// 歌词字体缩放倍率（持久化）。
  static const _lyricScaleKey = 'settings.lyric_scale';
  double _lyricScale = 1.0;

  @override
  void initState() {
    super.initState();
    _displayMode = _initialLyricDisplayMode(widget.player.lyrics);
    _loadLyricScale();
    // 兜底：非点歌路径（恢复播放/静默失败）进页时歌词可能为空，补拉一次。
    unawaited(widget.player.ensureLyricsLoaded());
  }

  Future<void> _loadLyricScale() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() => _lyricScale = prefs.getDouble(_lyricScaleKey) ?? 1.0);
    }
  }

  Future<void> _setLyricScale(double scale) async {
    final clamped = scale.clamp(0.7, 1.6);
    setState(() => _lyricScale = clamped);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_lyricScaleKey, clamped);
  }

  @override
  bool get wantKeepAlive => true;

  @override
  void didUpdateWidget(covariant LyricPlayerPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.song.hash != widget.song.hash ||
        oldWidget.player.lyrics != widget.player.lyrics) {
      _displayMode = _normalizeLyricDisplayMode(
        widget.player.lyrics,
        _displayMode,
      );
    }
    // 同一首歌但歌词为空（之前请求失败）：切回来时再补拉一次。
    if (oldWidget.song.hash == widget.song.hash &&
        widget.player.lyrics.isEmpty) {
      unawaited(widget.player.ensureLyricsLoaded());
    }
  }

  LyricDisplayMode _initialLyricDisplayMode(List<LyricLine> lyrics) {
    final availableModes = availableLyricDisplayModes(lyrics);
    return availableModes.isNotEmpty
        ? availableModes.first
        : LyricDisplayMode.lyricsOnly;
  }

  LyricDisplayMode _normalizeLyricDisplayMode(
    List<LyricLine> lyrics,
    LyricDisplayMode currentMode,
  ) {
    final availableModes = availableLyricDisplayModes(lyrics);
    if (availableModes.contains(currentMode)) {
      return currentMode;
    }
    return availableModes.isNotEmpty
        ? availableModes.first
        : LyricDisplayMode.lyricsOnly;
  }

  void _toggleLyricDisplayMode() {
    final availableModes = availableLyricDisplayModes(widget.player.lyrics);
    if (availableModes.length <= 1) {
      return;
    }

    final currentIndex = availableModes.indexOf(_displayMode);
    final nextIndex = currentIndex >= 0
        ? (currentIndex + 1) % availableModes.length
        : 0;
    setState(() => _displayMode = availableModes[nextIndex]);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final availableModes = availableLyricDisplayModes(widget.player.lyrics);
    final canToggleLyricDisplayMode = availableModes.length > 1;
    final displayMode = _normalizeLyricDisplayMode(
      widget.player.lyrics,
      _displayMode,
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 18),
      child: Stack(
        children: [
          LyricViewport(
            player: widget.player,
            songHash: widget.song.hash,
            lyrics: widget.player.lyrics,
            activeIndex: widget.player.activeLyricIndex,
            seekRevision: widget.player.seekRevision,
            isPreparing: widget.player.isPreparing,
            displayMode: displayMode,
            focusRequest: widget.focusRequest,
            isPageActive: widget.isPageActive,
            isPageVisible: widget.isPageVisible,
            isPageTransitioning: widget.isPageTransitioning,
            lyricScale: _lyricScale,
          ),
          // 字体大小调节按钮（左侧底部）
          Positioned(
            left: 0,
            bottom: 16,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                GlassIconButton(
                  tooltip: '缩小歌词',
                  onPressed: () => _setLyricScale(_lyricScale - 0.1),
                  icon: Icons.text_decrease_rounded,
                ),
                const SizedBox(width: 8),
                GlassIconButton(
                  tooltip: '放大歌词',
                  onPressed: () => _setLyricScale(_lyricScale + 0.1),
                  icon: Icons.text_increase_rounded,
                ),
              ],
            ),
          ),
          if (canToggleLyricDisplayMode)
            Positioned(
              right: 0,
              bottom: 16,
              child: GlassIconButton(
                tooltip: '切换歌词模式（当前：${lyricDisplayModeLabel(displayMode)}）',
                onPressed: _toggleLyricDisplayMode,
                icon: switch (displayMode) {
                  LyricDisplayMode.lyricsWithTranslation =>
                    Icons.translate_rounded,
                  LyricDisplayMode.lyricsWithRomanization =>
                    Icons.record_voice_over_rounded,
                  LyricDisplayMode.lyricsOnly => Icons.lyrics_rounded,
                },
              ),
            ),
        ],
      ),
    );
  }
}

class LyricViewport extends StatefulWidget {
  const LyricViewport({
    super.key,
    required this.player,
    required this.songHash,
    required this.lyrics,
    required this.activeIndex,
    required this.seekRevision,
    required this.isPreparing,
    required this.displayMode,
    required this.focusRequest,
    required this.isPageActive,
    required this.isPageVisible,
    required this.isPageTransitioning,
    required this.lyricScale,
  });

  final PlayerController player;
  final String songHash;
  final List<LyricLine> lyrics;
  final int activeIndex;
  final int seekRevision;
  final bool isPreparing;
  final LyricDisplayMode displayMode;
  final int focusRequest;
  final bool isPageActive;
  final bool isPageVisible;
  final bool isPageTransitioning;
  final double lyricScale;

  @override
  State<LyricViewport> createState() => _LyricViewportState();
}

class _LyricViewportState extends State<LyricViewport>
    with SingleTickerProviderStateMixin {
  late final LyricController _lyricController;
  late final Ticker _ticker;
  // flutter_lyric 内部通过 isSelectingNotifier 标记用户是否在拖动歌词。
  // LyricView 是 CustomPaint 自绘，不产生 ScrollNotification，外层
  // NotificationListener 无效；改为监听 isSelectingNotifier 控制 ticker，
  // 用户拖动时停止 setProgress，避免与 flutter_lyric 内部 fling/恢复竞态。
  bool _isUserSelecting = false;

  @override
  void initState() {
    super.initState();
    _lyricController = LyricController();
    _lyricController.setOnTapLineCallback((position) {
      widget.player.seekToAndPlay(position);
    });
    _lyricController.isSelectingNotifier.addListener(_onSelectingChanged);
    _syncLyrics();
    _ticker = Ticker(_onTick);
    _syncTicker();
  }

  void _syncLyrics() {
    final lyrics = widget.lyrics;
    if (lyrics.isNotEmpty) {
      final showTranslation =
          widget.displayMode == LyricDisplayMode.lyricsWithTranslation;
      final showRomanization =
          widget.displayMode == LyricDisplayMode.lyricsWithRomanization;
      final model = convertToFlutterLyricModel(
        lyrics,
        showTranslation: showTranslation,
        showRomanization: showRomanization,
      );
      _lyricController.loadLyricModel(model);
    }
  }

  @override
  void didUpdateWidget(covariant LyricViewport oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.songHash != widget.songHash ||
        oldWidget.lyrics != widget.lyrics ||
        oldWidget.displayMode != widget.displayMode) {
      _syncLyrics();
    }
    _syncTicker();
  }

  @override
  void dispose() {
    _lyricController.isSelectingNotifier.removeListener(_onSelectingChanged);
    _ticker.dispose();
    _lyricController.dispose();
    super.dispose();
  }

  void _onSelectingChanged() {
    _isUserSelecting = _lyricController.isSelectingNotifier.value;
    _syncTicker();
  }

  void _syncTicker() {
    final shouldTick =
        widget.isPageVisible &&
        widget.player.isPlaying &&
        widget.lyrics.isNotEmpty &&
        !widget.player.isScrubbing &&
        !_isUserSelecting;
    if (shouldTick && !_ticker.isActive) {
      _ticker.start();
    } else if (!shouldTick && _ticker.isActive) {
      _ticker.stop();
    }
  }

  void _onTick(Duration elapsed) {
    if (!mounted || widget.player.isScrubbing) {
      return;
    }
    _lyricController.setProgress(widget.player.smoothPosition);
  }

  @override
  Widget build(BuildContext context) {
    final lyrics = widget.lyrics;
    if (lyrics.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              widget.isPreparing ? '正在准备音乐...' : '暂无歌词',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w800,
              ),
            ),
            // 非 preparing 且无歌词：大概率是之前请求失败，给手动重试入口。
            if (!widget.isPreparing)
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

    // 桌面端：flutter_lyric 的 LyricView 只处理触摸拖动，不响应鼠标滚轮；
    // 且控制器无对外滚动接口。用原生 ListView 实现 PC 式歌词列表：
    // 滚轮/触摸均可滚动，点击切歌，空闲自动跟随。
    if (isDesktopFormFactor) {
      return ExcludeSemantics(
        child: DesktopLyricList(
          player: widget.player,
          songHash: widget.songHash,
          lyrics: lyrics,
          activeIndex: widget.activeIndex,
          displayMode: widget.displayMode,
          lyricScale: widget.lyricScale,
        ),
      );
    }

    final normalSize = 27.0 * widget.lyricScale;
    final activeSize = 34.0 * widget.lyricScale;
    final translationSize = 16.0 * widget.lyricScale;

    final lyricStyle = LyricStyles.default1.copyWith(
      textStyle: Theme.of(context).textTheme.headlineMedium!.copyWith(
        color: Colors.white.withValues(alpha: .34),
        fontSize: normalSize,
        height: 1.24,
        fontWeight: FontWeight.w800,
      ),
      activeStyle: Theme.of(context).textTheme.headlineMedium!.copyWith(
        color: Colors.white.withValues(alpha: .34),
        fontSize: activeSize,
        height: 1.24,
        fontWeight: FontWeight.w900,
      ),
      translationStyle: Theme.of(context).textTheme.titleMedium!.copyWith(
        color: Colors.white.withValues(alpha: .54),
        fontSize: translationSize,
        height: 1.28,
        fontWeight: FontWeight.w700,
      ),
      lineGap: 28,
      translationLineGap: 8,
      contentPadding: const EdgeInsets.fromLTRB(20, 180, 20, 220),
      fadeRange: FadeRange(top: 80, bottom: 80),
      textAlign: TextAlign.start,
      contentAlignment: CrossAxisAlignment.start,
      activeAnchorPosition: 0.34,
      activeHighlightColor: Colors.white,
    );

    return ExcludeSemantics(
      // 歌词视图高频更新会触发 Windows AXTree 竞态崩溃，排除语义树
      child: LyricView(controller: _lyricController, style: lyricStyle),
    );
  }
}

class LyricText extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final style =
        styleOverride ??
        Theme.of(context).textTheme.headlineMedium!.copyWith(
          color: Colors.white,
          fontSize: active ? 34 : 27,
          height: 1.24,
          fontWeight: active ? FontWeight.w900 : FontWeight.w800,
        );

    if (!active || line.words.isEmpty) {
      if (singleLine) {
        return Text(
          line.text,
          textAlign: textAlign,
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.visible,
          style: style,
        );
      }
      return Text(line.text, textAlign: textAlign, style: style);
    }

    if (singleLine) {
      final painter = KaraokeLinePainter(
        line: line,
        position: position,
        style: style,
        baseColor: Colors.white.withValues(alpha: .34),
        activeColor: Colors.white,
        textDirection: Directionality.of(context),
        textAlign: textAlign,
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
        final painter = KaraokeLinePainter(
          line: line,
          position: position,
          style: style,
          baseColor: Colors.white.withValues(alpha: .34),
          activeColor: Colors.white,
          textDirection: Directionality.of(context),
          textAlign: textAlign,
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
