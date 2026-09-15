import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../controllers/player_controller.dart';
import '../../models/music_models.dart';
import 'lyric_display_mode.dart';
import 'lyric_karaoke_text.dart';

/// 桌面端歌词列表（PC 软件逻辑，对齐 QQ 音乐/网易云 PC）。
///
/// - 滚轮/触摸均可自由滚动歌词（flutter_lyric 自绘视图不消费滚轮，故用原生
///   ListView 实现）；点击行跳转播放；
/// - 用户滚动时暂停自动跟随（高亮仍随播放更新），停止滚动 3s 后平滑恢复
///   跟随当前行（主流 PC 播放器一致：QQ/网易云均为“手动查看 + 空闲恢复”，
///   本实现 3s 与业界常用值一致）；
/// - 手动滚动期间右下角出现“回到当前”快捷入口，点按立即恢复跟随；
/// - 当前播放行有逐字时间戳时渲染逐字卡拉OK扫色（与移动端同款
///   [LyricText]/[KaraokeLinePainter]，painter 缓存排版、每帧仅重绘当前行）。
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

class _DesktopLyricListState extends State<DesktopLyricList>
    with TickerProviderStateMixin {
  // 主流 PC 播放器（QQ 音乐/网易云）用户干预后约 3.5s 恢复自动跟随。
  static const _resumeDelay = Duration(milliseconds: 3500);

  late final ScrollController _scrollController;
  final _rowKeys = <int, GlobalKey>{};
  Timer? _resumeTimer;
  var _userHolding = false;
  late int _activeLyricIndex;
  int? _focusedIndex;
  late final Ticker _ticker;

  /// 卡拉OK 逐帧驱动的平滑播放位置。
  Duration _smoothPosition = Duration.zero;

  /// 自动定位令牌：每次 [_scrollToActive] 自增，使旧的收敛回调自我作废。
  int _revealToken = 0;

  @override
  void initState() {
    super.initState();
    _activeLyricIndex = widget.player.lyrics.isEmpty
        ? -1
        : widget.player.activeLyricIndex;
    if (_activeLyricIndex < 0 && widget.activeIndex >= 0) {
      _activeLyricIndex = widget.activeIndex;
    }
    _smoothPosition = widget.player.smoothPosition;

    final initialOffset = _estimateOffsetForIndex(_activeLyricIndex);
    _scrollController = ScrollController(initialScrollOffset: initialOffset);

    widget.player.positionListenable.addListener(_onPositionChanged);
    _ticker = createTicker(_onTick);
    _syncTicker();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scrollToActive(animate: false);
    });
  }

  void _syncTicker() {
    final shouldTick =
        widget.player.isPlaying &&
        widget.lyrics.isNotEmpty &&
        !widget.player.isScrubbing;
    if (shouldTick && !_ticker.isActive) {
      _ticker.start();
    } else if (!shouldTick && _ticker.isActive) {
      _ticker.stop();
    }
  }

  void _onTick(Duration elapsed) {
    if (!mounted || widget.player.isScrubbing) return;
    final pos = widget.player.smoothPosition;
    if ((_smoothPosition.inMilliseconds - pos.inMilliseconds).abs() > 20) {
      setState(() => _smoothPosition = pos);
    }
  }

  void _onPositionChanged() {
    if (!mounted) return;
    _syncTicker();
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
      _smoothPosition = widget.player.smoothPosition;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _scrollToActive(animate: false);
      });
      _syncTicker();
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
    _syncTicker();
  }

  @override
  void dispose() {
    _ticker.dispose();
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

  /// 取目标行的 RenderBox；行未构建（在 ListView 构建窗口之外）时为 null。
  RenderBox? _rowBox(int index) {
    final ctx = _rowKeys[index]?.currentContext;
    if (ctx == null || !ctx.mounted) return null;
    final box = ctx.findRenderObject();
    return (box is RenderBox && box.hasSize) ? box : null;
  }

  /// 判断目标行相对当前构建窗口的方向：1 = 在下方（需向下滚），-1 = 在上方。
  /// ListView 按连续区间构建行，与视口相交的行必然已构建，因此用它们的
  /// 索引范围即可可靠推断未构建目标的方向。
  int _directionToIndex(int target) {
    final viewportBox = context.findRenderObject() as RenderBox?;
    if (viewportBox == null || !viewportBox.hasSize) return 0;
    int? minAlive;
    int? maxAlive;
    for (final entry in _rowKeys.entries) {
      final ctx = entry.value.currentContext;
      if (ctx == null || !ctx.mounted) continue;
      final box = ctx.findRenderObject();
      if (box is! RenderBox || !box.hasSize) continue;
      final top = box.localToGlobal(Offset.zero, ancestor: viewportBox).dy;
      final bottom = top + box.size.height;
      if (bottom < -100 || top > viewportBox.size.height + 100) continue;
      minAlive = (minAlive == null) ? entry.key : math.min(minAlive, entry.key);
      maxAlive = (maxAlive == null) ? entry.key : math.max(maxAlive, entry.key);
    }
    if (minAlive == null || maxAlive == null) return 0;
    if (target > maxAlive) return 1;
    if (target < minAlive) return -1;
    return 0;
  }

  /// 把目标行对齐到 38% 焦点线。与旧 `Scrollable.ensureVisible(alignment: 0.38)`
  /// 保持同一行顶对齐公式（行顶 = 0.38×(视口高−行高)），不改变既有几何行为；
  /// 移动端另有按行中心对齐的变体。
  void _alignRowToFocus(RenderBox rowBox, {required bool animate}) {
    final viewportBox = context.findRenderObject() as RenderBox?;
    if (viewportBox == null || !viewportBox.hasSize) return;
    final rowTop = rowBox.localToGlobal(Offset.zero, ancestor: viewportBox).dy;
    final viewportHeight = viewportBox.size.height;
    final position = _scrollController.position;
    final target =
        (position.pixels +
                rowTop -
                0.38 * (viewportHeight - rowBox.size.height))
            .clamp(position.minScrollExtent, position.maxScrollExtent);
    if ((target - position.pixels).abs() < 0.5) return;
    if (animate) {
      position.animateTo(
        target,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
      );
    } else {
      position.jumpTo(target);
    }
  }

  void _scrollToActive({required bool animate}) {
    if (!mounted ||
        _activeLyricIndex < 0 ||
        widget.lyrics.isEmpty ||
        !_scrollController.hasClients) {
      return;
    }
    final token = ++_revealToken;
    _revealPass(token, animate: animate, passesLeft: 16);
  }

  /// 定位当前行。目标行未构建时（深列表 + 行高估算偏差，估算落点可能离
  /// 目标成百上千像素）不能只试一次：按已构建行的分布逐帧向目标方向跳
  /// 约一个视口，直到进入构建窗口再精确对齐。[passesLeft] 兜底防止死循环。
  void _revealPass(int token, {required bool animate, required int passesLeft}) {
    if (token != _revealToken || !mounted) return;
    if (_userHolding || !_scrollController.hasClients) return;

    final index = _activeLyricIndex.clamp(0, widget.lyrics.length - 1);
    final box = _rowBox(index);
    if (box != null) {
      _alignRowToFocus(box, animate: animate);
      return;
    }
    if (passesLeft <= 0) return;

    final direction = _directionToIndex(index);
    if (direction == 0) return;
    final position = _scrollController.position;
    final step = math.max(position.viewportDimension, 200) * 1.2;
    position.jumpTo(
      (position.pixels + direction * step).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      ),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _revealPass(token, animate: animate, passesLeft: passesLeft - 1);
    });
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
                              // 当前播放行且有逐字时间戳：逐字卡拉OK扫色
                              //（painter 缓存排版，每帧只重绘这一行）。
                              if (isPlaying && line.words.isNotEmpty)
                                LyricText(
                                  line: line,
                                  active: true,
                                  position: _smoothPosition,
                                  styleOverride: Theme.of(context)
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
                                )
                              else
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
