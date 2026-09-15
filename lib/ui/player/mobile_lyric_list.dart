import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../controllers/player_controller.dart';
import '../../models/music_models.dart';
import 'lyric_views.dart';

/// 移动端 QQ 音乐风格歌词列表组件：
/// 1. 播放中当前句放大并逐字（KRC 卡拉OK）平滑高亮；
/// 2. 手指滑动暂停自动跟随，计算视口黄金对焦中线（~38%~40% 高度）最近的行，
///    中线歌词色彩加重（纯白粗体）；
/// 3. 滑动时在中线右侧浮现 [ ▶ mm:ss ] 播放准星胶囊，点击立即跳转播放并恢复跟随；
/// 4. 停止滑动 3.5 秒后自动恢复跟随播放行；
/// 5. 独立支持翻译行与拼音/音译行展示。
class MobileLyricList extends StatefulWidget {
  const MobileLyricList({
    super.key,
    required this.player,
    required this.songHash,
    required this.lyrics,
    required this.activeIndex,
    required this.showTranslation,
    required this.showRomanization,
    required this.lyricScale,
    required this.isPageVisible,
  });

  final PlayerController player;
  final String songHash;
  final List<LyricLine> lyrics;
  final int activeIndex;
  final bool showTranslation;
  final bool showRomanization;
  final double lyricScale;
  final bool isPageVisible;

  @override
  State<MobileLyricList> createState() => _MobileLyricListState();
}

class _MobileLyricListState extends State<MobileLyricList>
    with SingleTickerProviderStateMixin {
  static const _resumeDelay = Duration(milliseconds: 3500);

  late final ScrollController _scrollController;
  final _rowKeys = <int, GlobalKey>{};
  Timer? _resumeTimer;
  var _userHolding = false;
  late int _activeLyricIndex;
  int? _focusedIndex;
  Duration _smoothPosition = Duration.zero;
  late final Ticker _ticker;

  /// 自动定位令牌：每次 [_scrollToActive] 自增，使旧的收敛回调自我作废。
  int _revealToken = 0;

  @override
  void initState() {
    super.initState();
    _activeLyricIndex = widget.lyrics.isEmpty
        ? -1
        : (widget.activeIndex >= 0
              ? widget.activeIndex
              : widget.player.activeLyricIndex);
    _smoothPosition = widget.player.smoothPosition;

    final initialOffset = _estimateOffsetForIndex(_activeLyricIndex);
    _scrollController = ScrollController(initialScrollOffset: initialOffset);

    widget.player.positionListenable.addListener(_onPositionListenableChanged);

    _ticker = createTicker(_onTick);
    _syncTicker();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.isPageVisible) _scrollToActive(animate: false);
    });
  }

  void _syncTicker() {
    final shouldTick =
        widget.isPageVisible &&
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
    final newIndex = widget.player.activeLyricIndex;

    var needSetState = false;
    if ((_smoothPosition.inMilliseconds - pos.inMilliseconds).abs() > 20) {
      _smoothPosition = pos;
      needSetState = true;
    }

    if (newIndex != _activeLyricIndex) {
      _activeLyricIndex = newIndex;
      needSetState = true;
      if (!_userHolding) {
        _scrollToActive(animate: true);
      }
    }

    if (needSetState) {
      setState(() {});
    }
  }

  void _onPositionListenableChanged() {
    if (!mounted) return;
    final newIndex = widget.player.activeLyricIndex;
    final pos = widget.player.position;

    if (newIndex != _activeLyricIndex || _smoothPosition != pos) {
      setState(() {
        _activeLyricIndex = newIndex;
        _smoothPosition = pos;
      });
      if (!_userHolding && !_ticker.isActive) {
        _scrollToActive(animate: true);
      }
    }
  }

  @override
  void didUpdateWidget(covariant MobileLyricList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.player != widget.player) {
      oldWidget.player.positionListenable.removeListener(
        _onPositionListenableChanged,
      );
      widget.player.positionListenable.addListener(
        _onPositionListenableChanged,
      );
    }
    if (oldWidget.songHash != widget.songHash) {
      _rowKeys.clear();
      _resumeTimer?.cancel();
      _userHolding = false;
      _focusedIndex = null;
      _activeLyricIndex = widget.lyrics.isEmpty
          ? -1
          : (widget.activeIndex >= 0
                ? widget.activeIndex
                : widget.player.activeLyricIndex);
      _smoothPosition = widget.player.smoothPosition;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _scrollToActive(animate: false);
      });
      _syncTicker();
      return;
    }
    if (oldWidget.lyrics.length != widget.lyrics.length) {
      _activeLyricIndex = widget.lyrics.isEmpty
          ? -1
          : (widget.activeIndex >= 0
                ? widget.activeIndex
                : widget.player.activeLyricIndex);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_userHolding) _scrollToActive(animate: false);
      });
    } else if (widget.activeIndex != _activeLyricIndex) {
      _activeLyricIndex = widget.activeIndex;
      if (!_userHolding) {
        _scrollToActive(animate: true);
      }
    }
    if (!oldWidget.isPageVisible && widget.isPageVisible) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_userHolding) _scrollToActive(animate: false);
      });
    }
    _syncTicker();
  }

  @override
  void dispose() {
    _ticker.dispose();
    widget.player.positionListenable.removeListener(
      _onPositionListenableChanged,
    );
    _resumeTimer?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  double _estimateOffsetForIndex(int index) {
    if (index <= 0 || widget.lyrics.isEmpty) return 0.0;
    final clamped = index.clamp(0, widget.lyrics.length - 1);
    final hasSecondary = widget.showTranslation || widget.showRomanization;
    final rowHeight = (hasSecondary ? 68.0 : 46.0) * widget.lyricScale;
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

  /// 把目标行居中对齐到 38% 焦点线（按行中心而非行顶，长句换行时视觉更准）。
  void _alignRowToFocus(RenderBox rowBox, {required bool animate}) {
    final viewportBox = context.findRenderObject() as RenderBox?;
    if (viewportBox == null || !viewportBox.hasSize) return;
    final rowCenter = rowBox.localToGlobal(
      rowBox.size.center(Offset.zero),
      ancestor: viewportBox,
    );
    final targetY = viewportBox.size.height * 0.38;
    final position = _scrollController.position;
    final target =
        (position.pixels + rowCenter.dy - targetY).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        );
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
        !widget.isPageVisible ||
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
    if (token != _revealToken || !mounted || !widget.isPageVisible) return;
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

  void _onUserScroll(double viewportHeight) {
    if (!_userHolding) {
      _startUserHolding(viewportHeight);
      return;
    }
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

  void _resumeNow() {
    _resumeTimer?.cancel();
    if (!mounted) return;
    setState(() {
      _userHolding = false;
      _focusedIndex = null;
    });
    _scrollToActive(animate: true);
  }

  bool _handleScrollNotification(
    ScrollNotification notification,
    double viewportHeight,
  ) {
    if (notification is ScrollStartNotification) {
      if (notification.dragDetails != null) {
        _startUserHolding(viewportHeight);
      }
      return false;
    }
    if (notification is ScrollUpdateNotification ||
        notification is ScrollEndNotification) {
      if (_userHolding) {
        _onUserScroll(viewportHeight);
      }
      return false;
    }
    return false;
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
              child: NotificationListener<ScrollNotification>(
                onNotification: (notification) =>
                    _handleScrollNotification(notification, viewportHeight),
                child: ListView.builder(
                  controller: _scrollController,
                  physics: const AlwaysScrollableScrollPhysics(
                    parent: BouncingScrollPhysics(),
                  ),
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
                    final key = _rowKeys.putIfAbsent(index, GlobalKey.new);

                    final showTrans =
                        widget.showTranslation &&
                        line.translation != null &&
                        line.translation!.isNotEmpty;
                    final showRom =
                        widget.showRomanization &&
                        line.romanization != null &&
                        line.romanization!.isNotEmpty;

                    // 1. 正在播放（isPlaying）：无论是否滑动，大字号、粗字重
                    // 2. 滚动到的歌词（isFocused && !isPlaying）：不用变大，保持标准字号与字重
                    // 3. 其他非播放歌词：标准字号与字重
                    final double fontSize =
                        (isPlaying ? 26.0 : 20.0) * widget.lyricScale;
                    final fontWeight = isPlaying
                        ? FontWeight.w900
                        : FontWeight.w700;

                    // 颜色层级：
                    // - 正在播放：高亮白（若有逐字打点则由 LyricText 动态渐变呈现）
                    // - 滑动时中心线定位歌词：颜色稍微加深/加亮至 alpha 0.85，清晰醒目但不变大
                    // - 普通未播放歌词：alpha 0.35 优雅半透明
                    final Color mainColor;
                    if (isPlaying) {
                      mainColor = Colors.white;
                    } else if (isFocused) {
                      mainColor = Colors.white.withValues(alpha: 0.85);
                    } else {
                      mainColor = Colors.white.withValues(alpha: 0.35);
                    }

                    final mainTextStyle = Theme.of(context)
                        .textTheme
                        .headlineMedium!
                        .copyWith(
                          color: mainColor,
                          fontSize: fontSize,
                          height: 1.28,
                          fontWeight: fontWeight,
                        );

                    Widget mainWidget;
                    // 正在播放且有逐字时间戳：即使滑动中也持续运行逐字卡拉OK动效，样式永不丢失
                    if (isPlaying && line.words.isNotEmpty) {
                      mainWidget = LyricText(
                        line: line,
                        active: true,
                        position: _smoothPosition,
                        styleOverride: mainTextStyle,
                        textAlign: TextAlign.start,
                      );
                    } else {
                      mainWidget = AnimatedDefaultTextStyle(
                        duration: const Duration(milliseconds: 180),
                        style: mainTextStyle,
                        child: Text(line.text),
                      );
                    }

                    final Color transColor;
                    if (isPlaying) {
                      transColor = Colors.white.withValues(alpha: 0.85);
                    } else if (isFocused) {
                      transColor = Colors.white.withValues(alpha: 0.70);
                    } else {
                      transColor = Colors.white.withValues(alpha: 0.28);
                    }

                    final Color romColor;
                    if (isPlaying) {
                      romColor = Colors.white.withValues(alpha: 0.80);
                    } else if (isFocused) {
                      romColor = Colors.white.withValues(alpha: 0.65);
                    } else {
                      romColor = Colors.white.withValues(alpha: 0.25);
                    }

                    return GestureDetector(
                      key: key,
                      behavior: HitTestBehavior.opaque,
                      onTap: () {
                        widget.player.seekToAndPlay(line.time);
                        _activeLyricIndex = index;
                        _resumeNow();
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8.5),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            mainWidget,
                            if (showTrans) ...[
                              const SizedBox(height: 4),
                              Text(
                                line.translation!,
                                style: TextStyle(
                                  color: transColor,
                                  fontSize: 14.5 * widget.lyricScale,
                                  height: 1.26,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                            if (showRom) ...[
                              const SizedBox(height: 3),
                              Text(
                                line.romanization!,
                                style: TextStyle(
                                  color: romColor,
                                  fontSize: 13.5 * widget.lyricScale,
                                  height: 1.24,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),

            // 准星参考线与右侧时间胶囊播放按钮 [ ▶ mm:ss ]
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
                              Colors.white.withValues(alpha: 0.08),
                              Colors.white.withValues(alpha: 0.28),
                              Colors.white.withValues(alpha: 0.14),
                            ],
                          ),
                        ),
                      ),
                    ),
                    _MobileSeekPointerButton(
                      key: const ValueKey('mobile_lyric_seek_pointer_button'),
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
          ],
        );
      },
    );
  }
}

/// 移动端 QQ 音乐同款时间播放胶囊 [ ▶ mm:ss ]
class _MobileSeekPointerButton extends StatelessWidget {
  const _MobileSeekPointerButton({
    super.key,
    required this.timeText,
    required this.onTap,
  });

  final String timeText;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4.5),
        decoration: BoxDecoration(
          color: const Color(0x33000000),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.32),
            width: 1,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.25),
              blurRadius: 6,
              offset: const Offset(0, 1),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.play_arrow_rounded, size: 14, color: Colors.white),
            const SizedBox(width: 3),
            Text(
              timeText,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.3,
                height: 1,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
