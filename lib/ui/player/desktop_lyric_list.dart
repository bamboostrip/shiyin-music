import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../controllers/player_controller.dart';
import '../../models/music_models.dart';
import 'lyric_display_mode.dart';

/// 桌面端歌词列表（PC 软件逻辑，对齐 QQ 音乐/网易云 PC）。
///
/// - 滚轮/触摸均可自由滚动歌词（flutter_lyric 自绘视图不消费滚轮，故用原生
///   ListView 实现）；点击行跳转播放；
/// - 用户滚动时暂停自动跟随（高亮仍随播放更新），停止滚动 3s 后平滑恢复
///   跟随当前行（主流 PC 播放器一致：QQ/网易云均为“手动查看 + 空闲恢复”，
///   本实现 3s 与业界常用值一致）；
/// - 手动滚动期间右下角出现“回到当前”快捷入口，点按立即恢复跟随。
class DesktopLyricList extends StatefulWidget {
  const DesktopLyricList({
    super.key,
    required this.player,
    required this.songHash,
    required this.lyrics,
    required this.activeIndex,
    required this.displayMode,
    required this.lyricScale,
  });

  final PlayerController player;
  final String songHash;
  final List<LyricLine> lyrics;
  final int activeIndex;
  final LyricDisplayMode displayMode;
  final double lyricScale;

  @override
  State<DesktopLyricList> createState() => _DesktopLyricListState();
}

class _DesktopLyricListState extends State<DesktopLyricList> {
  // 主流 PC 播放器（QQ 音乐/网易云）用户干预后约 3.5s 恢复自动跟随。
  static const _resumeDelay = Duration(milliseconds: 3500);

  late final ScrollController _scrollController;
  final _rowKeys = <int, GlobalKey>{};
  Timer? _resumeTimer;
  var _userHolding = false;
  late int _activeLyricIndex;
  int? _focusedIndex;

  @override
  void initState() {
    super.initState();
    _activeLyricIndex = widget.player.lyrics.isEmpty
        ? -1
        : widget.player.activeLyricIndex;
    if (_activeLyricIndex < 0 && widget.activeIndex >= 0) {
      _activeLyricIndex = widget.activeIndex;
    }

    final initialOffset = _estimateOffsetForIndex(_activeLyricIndex);
    _scrollController = ScrollController(initialScrollOffset: initialOffset);

    widget.player.positionListenable.addListener(_onPositionChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scrollToActive(animate: false);
    });
  }

  void _onPositionChanged() {
    if (!mounted) return;
    final newIndex = widget.player.activeLyricIndex;
    if (widget.player.isPreparing && newIndex <= 0 && _activeLyricIndex > 0) {
      return;
    }
    if (newIndex != _activeLyricIndex) {
      setState(() {
        _activeLyricIndex = newIndex;
      });
      if (!_userHolding) {
        _scrollToActive(animate: true);
      }
    }
  }

  @override
  void didUpdateWidget(covariant DesktopLyricList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.player != widget.player) {
      oldWidget.player.positionListenable.removeListener(_onPositionChanged);
      widget.player.positionListenable.addListener(_onPositionChanged);
    }
    if (oldWidget.songHash != widget.songHash) {
      _rowKeys.clear();
      _resumeTimer?.cancel();
      _userHolding = false;
      _focusedIndex = null;
      _activeLyricIndex = widget.player.lyrics.isEmpty
          ? -1
          : widget.player.activeLyricIndex;
      if (_activeLyricIndex < 0 && widget.activeIndex >= 0) {
        _activeLyricIndex = widget.activeIndex;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _scrollToActive(animate: false);
      });
      return;
    }
    // 歌词异步加载完成（空 -> 有）时补一次定位；首帧行 key 尚未创建，
    // 放到 postFrame 等行构建完再滚。
    if (oldWidget.lyrics.length != widget.lyrics.length) {
      _activeLyricIndex = widget.player.lyrics.isEmpty
          ? -1
          : widget.player.activeLyricIndex;
      if (_activeLyricIndex < 0 && widget.activeIndex >= 0) {
        _activeLyricIndex = widget.activeIndex;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_userHolding) _scrollToActive(animate: false);
      });
      return;
    }
    if (widget.activeIndex != _activeLyricIndex) {
      if (widget.player.isPreparing &&
          widget.activeIndex <= 0 &&
          _activeLyricIndex > 0) {
        return;
      }
      _activeLyricIndex = widget.activeIndex;
      if (!_userHolding) {
        _scrollToActive(animate: true);
      }
    }
  }

  @override
  void dispose() {
    widget.player.positionListenable.removeListener(_onPositionChanged);
    _resumeTimer?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  double _estimateOffsetForIndex(int index) {
    if (index <= 0 || widget.lyrics.isEmpty) return 0.0;
    final clamped = index.clamp(0, widget.lyrics.length - 1);
    final hasAnySecondary = widget.lyrics.any((l) => _secondaryText(l) != null);
    final rowHeight = (hasAnySecondary ? 70.0 : 48.0) * widget.lyricScale;
    return clamped * rowHeight;
  }

  void _scrollToActive({required bool animate}) {
    if (!mounted || _activeLyricIndex < 0 || widget.lyrics.isEmpty) return;
    final key = _rowKeys[_activeLyricIndex];
    final rowContext = key?.currentContext;
    if (rowContext != null && rowContext.mounted) {
      Scrollable.ensureVisible(
        rowContext,
        alignment: 0.38,
        duration: animate ? const Duration(milliseconds: 280) : Duration.zero,
        curve: Curves.easeOutCubic,
      );
      return;
    }

    // 若目标行尚未挂载（例如直接跳转较远距离），先估算跳到目标行附近以触发 ListView 构建
    if (_scrollController.hasClients) {
      final approxOffset = _estimateOffsetForIndex(_activeLyricIndex);
      _scrollController.jumpTo(
        approxOffset.clamp(0.0, _scrollController.position.maxScrollExtent),
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final retryContext = _rowKeys[_activeLyricIndex]?.currentContext;
        if (retryContext != null && retryContext.mounted) {
          Scrollable.ensureVisible(
            retryContext,
            alignment: 0.38,
            duration: animate
                ? const Duration(milliseconds: 280)
                : Duration.zero,
            curve: Curves.easeOutCubic,
          );
        }
      });
    }
  }

  void _updateFocusedIndex(double viewportHeight) {
    if (widget.lyrics.isEmpty) return;
    final targetY = viewportHeight * 0.38;
    int bestIndex = _activeLyricIndex.clamp(0, widget.lyrics.length - 1);
    double minDiff = double.infinity;

    final stackRender = context.findRenderObject() as RenderBox?;
    if (stackRender == null || !stackRender.hasSize) return;

    for (final entry in _rowKeys.entries) {
      final key = entry.value;
      final ctx = key.currentContext;
      if (ctx == null) continue;
      final box = ctx.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) continue;
      final localCenter = box.localToGlobal(
        Offset(0, box.size.height / 2),
        ancestor: stackRender,
      );
      final diff = (localCenter.dy - targetY).abs();
      if (diff < minDiff) {
        minDiff = diff;
        bestIndex = entry.key;
      }
    }

    if (_focusedIndex != bestIndex) {
      setState(() {
        _focusedIndex = bestIndex;
      });
    }
  }

  void _startUserHolding(double viewportHeight) {
    _resumeTimer?.cancel();
    if (!_userHolding) {
      _userHolding = true;
      _focusedIndex ??= _activeLyricIndex;
      setState(() {});
    }
    _updateFocusedIndex(viewportHeight);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _userHolding) {
        _updateFocusedIndex(viewportHeight);
      }
    });
    _resumeTimer = Timer(_resumeDelay, () {
      if (!mounted) return;
      _resumeNow();
    });
  }

  bool _handleScrollNotification(
    ScrollNotification notification,
    double viewportHeight,
  ) {
    if (notification is ScrollStartNotification) {
      if (notification.dragDetails != null && !_userHolding) {
        _startUserHolding(viewportHeight);
      }
      return false;
    }

    if (!_userHolding) return false;

    if (notification is ScrollUpdateNotification ||
        notification is ScrollEndNotification) {
      _resumeTimer?.cancel();
      _updateFocusedIndex(viewportHeight);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _userHolding) {
          _updateFocusedIndex(viewportHeight);
        }
      });
      _resumeTimer = Timer(_resumeDelay, () {
        if (!mounted) return;
        _resumeNow();
      });
    }
    return false;
  }

  void _resumeNow() {
    _resumeTimer?.cancel();
    if (!mounted) return;
    setState(() {
      _userHolding = false;
      _focusedIndex = null;
    });
    _scrollToActive(animate: true);
  }

  String? _secondaryText(LyricLine line) {
    return switch (widget.displayMode) {
      LyricDisplayMode.lyricsWithTranslation =>
        line.translation?.isNotEmpty == true ? line.translation : null,
      LyricDisplayMode.lyricsWithRomanization =>
        line.romanization?.isNotEmpty == true ? line.romanization : null,
      LyricDisplayMode.lyricsOnly => null,
    };
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewportHeight = constraints.maxHeight;
        final targetY = viewportHeight * 0.38;
        final defaultIdx = _activeLyricIndex.clamp(0, widget.lyrics.length - 1);
        final currentFocusIdx = _focusedIndex ?? defaultIdx;
        final focusedLine =
            (_userHolding &&
                currentFocusIdx >= 0 &&
                currentFocusIdx < widget.lyrics.length)
            ? widget.lyrics[currentFocusIdx]
            : null;

        return Stack(
          children: [
            Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: (_) => _startUserHolding(viewportHeight),
              onPointerSignal: (signal) {
                if (signal is PointerScrollEvent) {
                  _startUserHolding(viewportHeight);
                }
              },
              child: NotificationListener<ScrollNotification>(
                onNotification: (notification) =>
                    _handleScrollNotification(notification, viewportHeight),
                child: ListView.builder(
                  controller: _scrollController,
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: EdgeInsets.fromLTRB(
                    20,
                    targetY > 0 ? targetY : 120,
                    20,
                    viewportHeight * 0.48,
                  ),
                  itemCount: widget.lyrics.length,
                  itemBuilder: (context, index) {
                    final line = widget.lyrics[index];
                    final isPlaying = index == _activeLyricIndex;
                    final isFocused = _userHolding && index == _focusedIndex;
                    final isHighlighted = _userHolding ? isFocused : isPlaying;
                    final key = _rowKeys.putIfAbsent(index, GlobalKey.new);
                    final secondary = _secondaryText(line);

                    final Color textColor;
                    if (isHighlighted) {
                      textColor = Colors.white;
                    } else if (_userHolding && isPlaying) {
                      textColor = Colors.white.withValues(alpha: .52);
                    } else {
                      textColor = Colors.white.withValues(alpha: .32);
                    }

                    return GestureDetector(
                      key: key,
                      behavior: HitTestBehavior.opaque,
                      onTap: () {
                        widget.player.seekToAndPlay(line.time);
                        _activeLyricIndex = index;
                        _resumeNow();
                      },
                      child: MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 9),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              AnimatedDefaultTextStyle(
                                duration: const Duration(milliseconds: 180),
                                style: Theme.of(context)
                                    .textTheme
                                    .headlineMedium!
                                    .copyWith(
                                      color: textColor,
                                      fontSize:
                                          (isHighlighted ? 30.0 : 24.0) *
                                          widget.lyricScale,
                                      height: 1.3,
                                      fontWeight: isHighlighted
                                          ? FontWeight.w900
                                          : FontWeight.w700,
                                    ),
                                child: Text(line.text),
                              ),
                              if (secondary != null) ...[
                                const SizedBox(height: 4),
                                Text(
                                  secondary,
                                  style: Theme.of(context).textTheme.titleMedium
                                      ?.copyWith(
                                        color: Colors.white.withValues(
                                          alpha: isHighlighted
                                              ? .75
                                              : (_userHolding && isPlaying
                                                    ? .45
                                                    : .28),
                                        ),
                                        fontSize: 15.0 * widget.lyricScale,
                                        height: 1.3,
                                        fontWeight: FontWeight.w600,
                                      ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
            // 居中准星参考线与定位跳转播放按钮 [ ▶ mm:ss ]
            if (_userHolding && focusedLine != null)
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
                              Colors.white.withValues(alpha: 0.10),
                              Colors.white.withValues(alpha: 0.32),
                              Colors.white.withValues(alpha: 0.16),
                            ],
                          ),
                        ),
                      ),
                    ),
                    SeekPointerButton(
                      key: const ValueKey('lyric_seek_pointer_button'),
                      timeText: formatDuration(focusedLine.time),
                      onTap: () {
                        widget.player.seekToAndPlay(focusedLine.time);
                        _activeLyricIndex = currentFocusIdx;
                        _resumeNow();
                      },
                    ),
                  ],
                ),
              ),
            // 手动滚动期间的“回到当前”快捷入口（网易云/QQ 音乐 PC 同款逻辑，
            // 自动恢复前给用户手动立即跟随的出口）。
            if (_userHolding)
              Positioned(
                right: 12,
                bottom: 24,
                child: Material(
                  color: Colors.white.withValues(alpha: .14),
                  borderRadius: BorderRadius.circular(20),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: _resumeNow,
                    borderRadius: BorderRadius.circular(20),
                    child: const Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 8,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.my_location_rounded,
                            size: 16,
                            color: Colors.white,
                          ),
                          SizedBox(width: 6),
                          Text(
                            '回到当前',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
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

/// PC 端歌词定位播放准星按钮 [ ▶ mm:ss ]
class SeekPointerButton extends StatefulWidget {
  const SeekPointerButton({
    super.key,
    required this.timeText,
    required this.onTap,
  });

  final String timeText;
  final VoidCallback onTap;

  @override
  State<SeekPointerButton> createState() => _SeekPointerButtonState();
}

class _SeekPointerButtonState extends State<SeekPointerButton> {
  bool _isHovering = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _isHovering = true),
      onExit: (_) => setState(() => _isHovering = false),
      child: Tooltip(
        message: '从 ${widget.timeText} 开始播放',
        child: GestureDetector(
          onTap: widget.onTap,
          behavior: HitTestBehavior.opaque,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: _isHovering
                  ? primary
                  : const Color(0xFF1E212B).withValues(alpha: 0.85),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: _isHovering
                    ? primary
                    : Colors.white.withValues(alpha: 0.35),
                width: 1,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(
                    alpha: _isHovering ? 0.4 : 0.2,
                  ),
                  blurRadius: 10,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.play_arrow_rounded,
                  size: 16,
                  color: Colors.white,
                ),
                const SizedBox(width: 4),
                Text(
                  widget.timeText,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
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
