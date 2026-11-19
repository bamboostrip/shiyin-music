import 'dart:async' show unawaited;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../../config/app_config.dart';
import '../../controllers/auth_controller.dart';
import '../../controllers/player_controller.dart';
import '../../models/music_models.dart';
import '../player/player_route.dart';
import '../player/song_tap_handler.dart';
import 'artwork.dart';
import 'marquee_text.dart';
import 'queue_locate.dart';
import 'song_action_sheets.dart' show toggleLikeWithFeedback;
import 'toast.dart';

class CarLeftPlayerPanel extends StatelessWidget {
  const CarLeftPlayerPanel({
    super.key,
    required this.player,
    required this.auth,
  });

  final PlayerController player;
  final AuthController auth;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final sysPadding = MediaQuery.paddingOf(context);
    final availableHeight = size.height - sysPadding.top - sysPadding.bottom;

    // 车机左侧播放面板尺寸（issue #24）。
    //
    // 设计目标是**占比 ≈30% 屏宽**，参照 QQ 音乐车机版（按其车机截图实测：
    // 屏幕 185→1270px、面板右边界 ≈498px，约 29%）。这个数与旧实现的观感
    // 也对得上：旧版固定 380，在 1280 逻辑宽（1920×1080 屏 @dpr1.5，车机
    // 最常见的组合）上正好 29.7%——所以「原来 1080 上的比例」是 ~30%，
    // 不是 20%（20% 只在 dpr=1.0 的 1920 逻辑宽上出现，那种屏很少）。
    //
    // 这里等价于 web 的 flex 3:7——右侧内容区是 Expanded，吃掉剩下的 70%。
    // 不直接写 `Expanded(flex: 3)` 是因为小屏上 30% 放不下五个控制键，
    // 需要一条「可用性下限」，而 flex 表达不了 min-width。
    //
    // 所以**不设上限**：1280 逻辑宽 → 384、1707 → 512、1920 → 576、
    // 2560 → 768、3840 → 1152，永远 30%。issue #24 用户的 dpr 未实测
    // （日志导出时诊断头还没有 Screen 行），原生 dpr=1 就取 768、dpr1.5
    // 的 1707 就取 512——两种情况都是 30%，规则与 dpr 解耦。
    // 只保留下限（≥960 保底 380、<960 保底 320）与「可用高 × 0.62」收口
    // （32:9 超宽矮屏：2560×720 → 446，否则面板会又宽又扁）。
    //
    // 历史：v3.0.20 首版把目标占比定成了 1/3，1920 逻辑宽上从 380 涨到 634，
    // 又因为「封面上限 = 面板内宽全额」变成大图 + 两侧各 70dp 留白，观感
    // 反而比旧版差；这次把封面收成内容宽的 0.84，占比也从 33% 收到 30%。
    final double panelMinWidth = size.width < 960 ? 320.0 : 380.0;
    final double panelWidth = math
        .max(
          math.min(size.width * 0.30, availableHeight * 0.62),
          panelMinWidth,
        )
        .toDouble();

    // 可用高度连固定块都放不下（分屏/极小窗口）时直接留空面板，避免溢出。
    if (availableHeight < 280) {
      return SizedBox(width: panelWidth);
    }

    // 内部等比系数：以旧设计基线（380 宽 × 720 高）为 1.0。
    // 同时受宽、高约束：超宽矮屏（2560×720 这类 32:9）不能只按宽度放大，
    // 否则固定块变高一倍、封面会被挤到 24dp（历史溢出问题的另一种形态）。
    // 下限 0.85 对应 320 的小屏档（320/380 ≈ 0.84），比原先写死的 0.92
    // 更贴合旧的小屏参数（padding 14 / 播放键 56 / 图标 32）；上限 2.2 覆盖
    // 到 3840 逻辑宽（面板 1152），保证超大屏上封面/按键不会相对变小。
    final double scale = math
        .min(panelWidth / 380.0, availableHeight / 720.0)
        .clamp(0.85, 2.2)
        .toDouble();
    // 字号单独封顶：封面/按钮按 scale 全额放大，文字只跟到 1.7 倍，
    // 否则会和右侧内容区（14~16sp）脱节得太厉害。
    final textScale = math.min(scale, 1.7);
    final panelPadding = 20.0 * scale;

    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final isShortScreen = size.height < 500;
    final verticalPadding = (isShortScreen ? 8.0 : 20.0) * scale;
    final bottomGap = (isShortScreen ? 10.0 : 32.0) * scale;
    final controlsHeight = (isShortScreen ? 68.0 : 80.0) * scale;
    final gapSize = (isShortScreen ? 10.0 : 20.0) * scale;
    final titleGap = (isShortScreen ? 14.0 : 24.0) * scale;
    final progressGap = (isShortScreen ? 16.0 : 28.0) * scale;

    // 除封面外的固定块高度合计（header 28 + 歌名行 60 + 进度条 38 +
    // 控制条 + 各间距），随 scale 同比放大。封面高度必须扣掉它们，否则矮屏、
    // 车机界面缩放或系统字号放大把虚拟高度压小时，Column 会溢出（历史 720p
    // 车机在 130% 缩放下正好触发 12px 溢出）。
    final fixedContentHeight = (isShortScreen ? 244.0 : 310.0) * scale;
    // 28 = 封面边框 2.2 + 文字放大余量（歌名行高随系统/字体档位增长）。
    final artworkFitHeight =
        availableHeight -
        verticalPadding * 2 -
        fixedContentHeight -
        28.0 * scale;
    // issue #24：封面上限从固定 280 改为「面板内容宽 / 可用高度」共同决定。
    // 0.84 让封面在基线屏上等于旧值（(380-40)*0.84 ≈ 286，旧 280），
    // 宽屏随面板一起变大（1707×960 → 384、1920×1080 → 432、2560×1440 → 576，
    // 这几档实际由 0.40 高度上限收口），且始终留出两侧留白；0.40 高度上限
    // 防止 32:9 超宽矮屏上封面把控制条挤出去。
    final double artworkMax = math.min(
      (panelWidth - panelPadding * 2) * 0.84,
      availableHeight * 0.40,
    );
    // 上下界都是推导值，这里用 min/max 组合同等价钳制：clamp 在下界 > 上界时
    // 会抛 ArgumentError（极小窗口 + 极端缩放组合下可能出现），min/max 只会
    // 收敛到上界，布局最坏是封面偏小，绝不崩。
    final double artworkByHeight = math.min(
      math.max(
        availableHeight - (isShortScreen ? 250.0 : 340.0) * scale,
        80.0 * scale,
      ),
      artworkMax,
    );
    final double artworkSize = math.min(
      math.max(
        math.min(artworkByHeight, math.max(24.0, artworkFitHeight)),
        24.0,
      ),
      math.max(48.0 * scale, artworkMax),
    );

    final buttonMinWidth = 52.0 * scale;
    final playBtnSize = 64.0 * scale;
    final playIconSize = 40.0 * scale;

    return AnimatedBuilder(
      animation: player,
      builder: (context, _) {
        final song = player.currentSong;
        if (song == null) {
          return Container(
            width: panelWidth,
            color: colorScheme.surfaceContainer,
            padding: EdgeInsets.fromLTRB(
              panelPadding,
              sysPadding.top + verticalPadding,
              panelPadding,
              sysPadding.bottom + verticalPadding,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildHeader(
                  context,
                  colorScheme,
                  scale: scale,
                  textScale: textScale,
                ),
                const Expanded(
                  child: Center(
                    child: Text(
                      '暂无播放歌曲',
                      style: TextStyle(
                        color: Colors.grey,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        }

        final isPreparing = player.isPreparing;
        final playbackMode = player.playbackMode;

        return Container(
          width: panelWidth,
          padding: EdgeInsets.fromLTRB(
            panelPadding,
            sysPadding.top + verticalPadding,
            panelPadding,
            sysPadding.bottom + verticalPadding,
          ),
          color: colorScheme.surfaceContainer,
          child: ClipRect(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildHeader(
                  context,
                  colorScheme,
                  scale: scale,
                  textScale: textScale,
                ),
                const Spacer(),
                Center(
                  child: GestureDetector(
                    onTap: () => PlayerPageRoute.open(
                      context,
                      player: player,
                      auth: auth,
                    ),
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: isDark
                              ? Colors.white.withValues(alpha: .10)
                              : Colors.white.withValues(alpha: .92),
                          width: 1.1,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(
                              alpha: isDark ? .22 : .10,
                            ),
                            blurRadius: 14,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(20),
                        child: Artwork(
                          url: song.coverUrl,
                          size: artworkSize,
                          borderRadius: 20,
                        ),
                      ),
                    ),
                  ),
                ),
                SizedBox(height: gapSize),
                Row(
                  children: [
                    Expanded(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => PlayerPageRoute.open(
                          context,
                          player: player,
                          auth: auth,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            MarqueeText.text(
                              song.title,
                              style: Theme.of(context).textTheme.titleMedium
                                  ?.copyWith(
                                    fontWeight: FontWeight.w900,
                                    fontSize: 18 * textScale,
                                  ),
                            ),
                            SizedBox(height: 4 * scale),
                            Text(
                              song.artist,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(
                                    color: colorScheme.onSurfaceVariant,
                                    fontWeight: FontWeight.w600,
                                    // 与歌名同乘一档：歌名放到 26、副标题还是
                                    // 14 会显得头重脚轻（issue #24 截图里
                                    // QQ 车机版两行字号是成比例的）。
                                    fontSize:
                                        (Theme.of(
                                              context,
                                            ).textTheme.bodyMedium?.fontSize ??
                                            14.0) *
                                        textScale,
                                  ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    AnimatedBuilder(
                      animation: auth,
                      builder: (context, _) {
                        final liked = auth.isLiked(song);
                        // 车机远距离触控：收藏按钮加大，保证 >=48dp 触控目标。
                        // 不再设绝对上限（旧版写死 76/44）：scale 现在能到 2.2，
                        // 卡在 76 会让大屏上的爱心只有播放键一半大。
                        final favBtnSize = 60.0 * scale;
                        final favIconSize = 34.0 * scale;
                        return Container(
                          width: favBtnSize,
                          height: favBtnSize,
                          decoration: BoxDecoration(
                            color: liked
                                ? Colors.redAccent.withValues(alpha: .12)
                                : (isDark
                                      ? Colors.white.withValues(alpha: .08)
                                      : colorScheme.surfaceContainerHighest
                                            .withValues(alpha: .9)),
                            shape: BoxShape.circle,
                          ),
                          child: IconButton(
                            padding: EdgeInsets.zero,
                            onPressed: song.source == SongSource.kugou
                                ? () => toggleLikeWithFeedback(auth, song)
                                : null,
                            icon: Icon(
                              liked
                                  ? Icons.favorite_rounded
                                  : Icons.favorite_border_rounded,
                              color: liked
                                  ? Colors.redAccent
                                  : colorScheme.onSurfaceVariant,
                              size: favIconSize,
                            ),
                          ),
                        );
                      },
                    ),
                  ],
                ),
                SizedBox(height: titleGap),
                _CarProgressBar(
                  player: player,
                  colorScheme: colorScheme,
                  isDark: isDark,
                  scale: scale,
                  textScale: textScale,
                ),
                SizedBox(height: progressGap),
                Container(
                  height: controlsHeight,
                  decoration: BoxDecoration(
                    color: isDark
                        ? Colors.white.withValues(alpha: .06)
                        : Colors.white,
                    // 胶囊圆角跟随控制条高度（旧值固定 40 是按 80 高算的，
                    // 放大后不再等于半高，会变成「圆角矩形」而不是胶囊）。
                    borderRadius: BorderRadius.circular(controlsHeight / 2),
                    border: Border.all(
                      color: isDark
                          ? Colors.white.withValues(alpha: .10)
                          : Colors.white.withValues(alpha: .92),
                      width: 1.1,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(
                          alpha: isDark ? .18 : .06,
                        ),
                        blurRadius: 10,
                        offset: const Offset(0, 3),
                      ),
                    ],
                  ),
                  padding: EdgeInsets.symmetric(horizontal: 12 * scale),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      IconButton(
                        padding: EdgeInsets.zero,
                        constraints: BoxConstraints(
                          minWidth: buttonMinWidth,
                          minHeight: buttonMinWidth,
                        ),
                        icon: Icon(
                          _getPlaybackModeIcon(playbackMode),
                          size: 28 * scale,
                          color: colorScheme.onSurface,
                        ),
                        onPressed: player.cyclePlaybackMode,
                      ),
                      IconButton(
                        padding: EdgeInsets.zero,
                        constraints: BoxConstraints(
                          minWidth: buttonMinWidth,
                          minHeight: buttonMinWidth,
                        ),
                        icon: Icon(
                          Icons.skip_previous_rounded,
                          size: 36 * scale,
                          color: colorScheme.onSurface,
                        ),
                        onPressed: isPreparing ? null : player.previous,
                      ),
                      Container(
                        width: playBtnSize,
                        height: playBtnSize,
                        decoration: BoxDecoration(
                          color: colorScheme.primary,
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: colorScheme.primary.withValues(alpha: .35),
                              blurRadius: 12,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        child: IconButton(
                          padding: EdgeInsets.zero,
                          icon: AnimatedBuilder(
                            animation: player,
                            builder: (_, _) => Icon(
                              player.isPlaying
                                  ? Icons.pause_rounded
                                  : Icons.play_arrow_rounded,
                              color: colorScheme.onPrimary,
                              size: playIconSize,
                            ),
                          ),
                          onPressed: isPreparing ? null : player.togglePlay,
                        ),
                      ),
                      IconButton(
                        padding: EdgeInsets.zero,
                        constraints: BoxConstraints(
                          minWidth: buttonMinWidth,
                          minHeight: buttonMinWidth,
                        ),
                        icon: Icon(
                          Icons.skip_next_rounded,
                          size: 36 * scale,
                          color: colorScheme.onSurface,
                        ),
                        onPressed: isPreparing ? null : player.next,
                      ),
                      IconButton(
                        padding: EdgeInsets.zero,
                        constraints: BoxConstraints(
                          minWidth: buttonMinWidth,
                          minHeight: buttonMinWidth,
                        ),
                        icon: Icon(
                          Icons.queue_music_rounded,
                          size: 28 * scale,
                          color: colorScheme.onSurface,
                        ),
                        onPressed: () => _showQueue(context),
                      ),
                    ],
                  ),
                ),
                const Spacer(),
                SizedBox(height: bottomGap),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 面板顶部品牌行。
  ///
  /// [scale] / [textScale] 与面板内部等比系数同步：高分车机上歌名已放大到
  /// 26~30，若品牌行还是 28dp 图标 + 14sp 文字会明显失衡（issue #24）。
  Widget _buildHeader(
    BuildContext context,
    ColorScheme colorScheme, {
    double scale = 1.0,
    double textScale = 1.0,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Row(
      children: [
        Container(
          width: 28 * scale,
          height: 28 * scale,
          decoration: BoxDecoration(
            color: colorScheme.primary.withValues(alpha: isDark ? .18 : .10),
            borderRadius: BorderRadius.circular(8 * scale),
          ),
          child: Icon(
            Icons.music_note_rounded,
            color: colorScheme.primary,
            size: 16 * scale,
          ),
        ),
        SizedBox(width: 8 * scale),
        Text(
          AppConfig.appName,
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w900,
            color: colorScheme.onSurface,
            fontSize:
                (Theme.of(context).textTheme.titleSmall?.fontSize ?? 14.0) *
                textScale,
          ),
        ),
      ],
    );
  }

  IconData _getPlaybackModeIcon(PlaybackMode mode) {
    return switch (mode) {
      PlaybackMode.playlistLoop => Icons.repeat_rounded,
      PlaybackMode.shuffle => Icons.shuffle_rounded,
      PlaybackMode.singleLoop => Icons.repeat_one_rounded,
    };
  }

  void _showQueue(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (_) => _CarQueueSheetBody(player: player),
    );
  }

  static String _formatDuration(Duration d) {
    if (d == Duration.zero) return '00:00';
    final minutes = d.inMinutes.toString().padLeft(2, '0');
    final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}

/// 车机队列面板主体：头部（标题/计数/定位/清空）+ 可滚动队列列表。
///
/// 与移动端 queue_sheet 同款「打开定位到正在播放行 + 头部定位按钮」
/// （issue #28）；行 UI 保留车机简化版（ListTile、无删除按钮，驾驶
/// 场景防误触）。清空为内联实现（驾驶时不断流语义与移动端一致）。
class _CarQueueSheetBody extends StatefulWidget {
  const _CarQueueSheetBody({required this.player});

  final PlayerController player;

  @override
  State<_CarQueueSheetBody> createState() => _CarQueueSheetBodyState();
}

class _CarQueueSheetBodyState extends State<_CarQueueSheetBody> {
  /// 两行 ListTile（title+subtitle）72 + 分隔 2。
  static const double _rowStride = 74;

  final GlobalKey _activeRowKey = GlobalKey();
  late final QueueLocateController _locate;
  Animation<double>? _entrance;
  bool _correctScheduled = false;

  int _indexOfCurrent() {
    final current = widget.player.currentSong;
    if (current == null) return -1;
    return widget.player.queue.indexWhere((song) => isSameSong(current, song));
  }

  @override
  void initState() {
    super.initState();
    _locate = QueueLocateController(
      rowStride: _rowStride,
      initialIndex: _indexOfCurrent(),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _entrance ??= ModalRoute.of(context)?.animation;
    if (_correctScheduled) return;
    _correctScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        // 首帧时取 index：首帧到入场结束之间切歌的话，首跳仍按旧
        // index 估算，精修段会跟随行 key 落到新当前行。
        _locate.correctWhenEntranceSettled(
          _entrance,
          _activeRowKey,
          index: _indexOfCurrent(),
          itemCount: widget.player.queue.length,
        );
      }
    });
  }

  @override
  void dispose() {
    _locate.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 头部监听 player，面板打开期间队列变化时保持刷新。
            AnimatedBuilder(
              animation: widget.player,
              builder: (context, _) {
                final activeIndex = _indexOfCurrent();
                return Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Row(
                    children: [
                      Text(
                        '播放队列',
                        style: Theme.of(context)
                            .textTheme
                            .titleLarge
                            ?.copyWith(fontWeight: FontWeight.w900),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '${widget.player.queue.length} 首',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                            ),
                      ),
                      const Spacer(),
                      // 定位到正在播放行（issue #28）。
                      IconButton(
                        tooltip: '定位到正在播放',
                        visualDensity: VisualDensity.compact,
                        onPressed: activeIndex >= 0
                            ? () => unawaited(
                                  _locate.locate(
                                    activeIndex,
                                    _activeRowKey,
                                    itemCount: widget.player.queue.length,
                                  ),
                                )
                            : null,
                        icon: const Icon(Icons.my_location_rounded, size: 20),
                        color: colorScheme.onSurfaceVariant,
                      ),
                      TextButton(
                        onPressed: widget.player.queue.length > 1
                            ? () {
                                final current = widget.player.currentSong;
                                if (current == null) return;
                                Navigator.of(context).pop();
                                // 与移动端队列语义对齐：静默换队不重载，驾驶时不断流
                                unawaited(widget.player.replaceQueue([current]));
                                Toast.success('已清空播放队列');
                              }
                            : null,
                        child: Text(
                          '清空',
                          style: TextStyle(color: colorScheme.error),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
            Flexible(
              child: AnimatedBuilder(
                animation: widget.player,
                builder: (context, _) {
                  if (widget.player.queue.isEmpty) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 32),
                      child: Center(
                        child: Text(
                          '播放队列为空',
                          style: Theme.of(context)
                              .textTheme
                              .bodyMedium
                              ?.copyWith(color: colorScheme.onSurfaceVariant),
                        ),
                      ),
                    );
                  }
                  // 行 key 只挂首个匹配行（重复歌曲防 GlobalKey 冲突）。
                  final activeIndex = _indexOfCurrent();
                  return ListView.separated(
                    controller: _locate.controller,
                    shrinkWrap: true,
                    itemCount: widget.player.queue.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 2),
                    itemBuilder: (context, index) {
                      final song = widget.player.queue[index];
                      final active =
                          isSameSong(widget.player.currentSong, song);
                      return KeyedSubtree(
                        key: index == activeIndex ? _activeRowKey : null,
                        child: ListTile(
                          selected: active,
                          leading: Artwork(
                            url: song.coverUrl,
                            size: 40,
                            borderRadius: 8,
                          ),
                          title: active
                              ? MarqueeText.text(
                                  song.title,
                                  style: TextStyle(
                                    color: colorScheme.primary,
                                    fontWeight: FontWeight.bold,
                                  ),
                                )
                              : Text(
                                  song.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                          subtitle: Text(song.artist),
                          trailing: active
                              ? Icon(
                                  widget.player.isPlaying
                                      ? Icons.equalizer_rounded
                                      : Icons.pause_rounded,
                                  color: colorScheme.primary,
                                )
                              : null,
                          onTap: () {
                            // 点当前行只关面板不重头播（与队列面板一致）
                            if (isSameSong(widget.player.currentSong, song)) {
                              Navigator.of(context).pop();
                              return;
                            }
                            Navigator.of(context).pop();
                            widget.player
                                .playSong(song, queue: widget.player.queue);
                          },
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CarProgressBar extends StatelessWidget {
  const _CarProgressBar({
    required this.player,
    required this.colorScheme,
    required this.isDark,
    this.scale = 1.0,
    this.textScale = 1.0,
  });

  final PlayerController player;
  final ColorScheme colorScheme;
  final bool isDark;

  /// 进度条/时间文字的等比系数（与面板内部尺寸同步放大，issue #24）。
  final double scale;
  final double textScale;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Duration>(
      valueListenable: player.positionListenable,
      builder: (context, _, _) {
        final duration = player.duration;
        final position = player.smoothPosition;
        final max = duration.inMilliseconds <= 0
            ? 1.0
            : duration.inMilliseconds.toDouble();
        final value = position.inMilliseconds.clamp(0, max.toInt()).toDouble();

        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3 * scale,
                thumbShape: RoundSliderThumbShape(
                  enabledThumbRadius: 5 * scale,
                ),
                overlayShape: RoundSliderOverlayShape(
                  overlayRadius: 10 * scale,
                ),
                activeTrackColor: colorScheme.primary,
                inactiveTrackColor: isDark
                    ? Colors.white.withValues(alpha: 0.16)
                    : Colors.black.withValues(alpha: 0.08),
                thumbColor: colorScheme.primary,
              ),
              child: Slider(
                value: value,
                max: max,
                onChanged: (val) =>
                    player.previewSeek(Duration(milliseconds: val.round())),
                onChangeEnd: (val) async {
                  try {
                    await player.seek(Duration(milliseconds: val.round()));
                  } catch (_) {
                    Toast.error('定位失败，请重试');
                  }
                },
              ),
            ),
            const SizedBox(height: 2),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  CarLeftPlayerPanel._formatDuration(position),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                    fontSize: 11 * textScale,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  CarLeftPlayerPanel._formatDuration(duration),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                    fontSize: 11 * textScale,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}
