import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../controllers/auth_controller.dart';
import '../../controllers/player_controller.dart';
import '../../models/music_models.dart';
import '../form_factor.dart';
import 'desktop_lyric_list.dart';
import 'lyric_bottom_bar.dart';
import 'lyric_display_mode.dart';
import 'mobile_lyric_list.dart';
import 'player_controls.dart';

export 'lyric_karaoke_text.dart';

/// 译/音显示开关持久化键（移动端歌词页与 PC/车机分栏播放页共用同一份设置）。
const String kLyricShowTranslationPrefKey = 'settings.lyric_show_translation';
const String kLyricShowRomanizationPrefKey = 'settings.lyric_show_romanization';

class LyricPlayerPage extends StatefulWidget {
  const LyricPlayerPage({
    super.key,
    required this.player,
    required this.song,
    required this.isPageVisible,
    this.auth,
    this.onArtistTap,
  });

  final PlayerController player;
  final Song song;
  final bool isPageVisible;
  final AuthController? auth;
  final ValueChanged<Song>? onArtistTap;

  @override
  State<LyricPlayerPage> createState() => _LyricPlayerPageState();
}

class _LyricPlayerPageState extends State<LyricPlayerPage>
    with AutomaticKeepAliveClientMixin {
  static const _lyricScaleKey = 'settings.lyric_scale';
  static const _showTranslationKey = kLyricShowTranslationPrefKey;
  static const _showRomanizationKey = kLyricShowRomanizationPrefKey;

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

  Widget _buildHeader(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 6, 16, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.song.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w900,
                    color: Colors.white,
                    letterSpacing: -0.2,
                  ),
                ),
                const SizedBox(height: 4),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => widget.onArtistTap?.call(widget.song),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          widget.song.artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: Colors.white70,
                          ),
                        ),
                      ),
                      if (widget.onArtistTap != null) ...[
                        const SizedBox(width: 2),
                        const Icon(
                          Icons.chevron_right_rounded,
                          size: 16,
                          color: Colors.white70,
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (widget.auth != null) ...[
            const SizedBox(width: 8),
            ListenableBuilder(
              listenable: widget.auth!,
              builder: (context, _) {
                final liked = widget.auth!.isLiked(widget.song);
                final likeEnabled = widget.song.source == SongSource.kugou;
                return SizedBox(
                  width: 44,
                  height: 44,
                  child: IconButton(
                    padding: EdgeInsets.zero,
                    iconSize: 24,
                    tooltip: liked ? '取消喜欢' : '喜欢',
                    onPressed: likeEnabled
                        ? () => widget.auth!.toggleLike(widget.song)
                        : null,
                    icon: Icon(
                      liked
                          ? Icons.favorite_rounded
                          : Icons.favorite_border_rounded,
                      color: liked
                          ? Colors.redAccent
                          : Colors.white.withValues(
                              alpha: likeEnabled ? .7 : .3,
                            ),
                    ),
                  ),
                );
              },
            ),
          ],
        ],
      ),
    );
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
      return Column(
        children: [
          if (!isDesktopFormFactor) _buildHeader(context),
          Expanded(
            child: Center(
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
            ),
          ),
        ],
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
          displayMode: lyricDisplayModeOf(
            showTranslation: _showTranslation,
            showRomanization: _showRomanization,
          ),
          lyricScale: _lyricScale,
        ),
      );
    }

    return Column(
      children: [
        _buildHeader(context),
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
