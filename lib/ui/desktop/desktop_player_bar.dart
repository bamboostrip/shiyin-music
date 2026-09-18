import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../controllers/auth_controller.dart';
import '../../controllers/player_controller.dart';
import '../../models/music_models.dart';
import '../pages/artist_detail_page.dart';
import '../player/player_comment_button.dart';
import '../player/player_route.dart';

export '../player/player_comment_button.dart' show formatCommentCount, PlayerCommentButton;
import '../widgets/artwork.dart';
import '../widgets/audio_effects_sheet.dart';
import '../widgets/audio_quality_sheet.dart';
import '../widgets/climax_slider_track.dart';
import '../widgets/desktop_anchored_menu.dart';
import '../widgets/desktop_queue_panel.dart';
import '../widgets/marquee_text.dart';
import '../widgets/playback_speed_sheet.dart';
import '../widgets/sleep_timer_sheet.dart';
import '../widgets/song_action_sheets.dart';
import '../widgets/toast.dart';
import 'player_bar_widgets.dart';

/// 秒数 → `mm:ss`（≥1h 时 `h:mm:ss`）。
String formatDuration(Duration d) {
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  final h = d.inHours;
  return h > 0 ? '$h:$m:$s' : '$m:$s';
}

/// 窄窗断点：<1100 左区收窄（按钮间距随之收紧，操作按钮不隐藏）。
const double kPlayerBarCompactBreakpoint = 1100;

/// 左区固定宽度（封面 + 曲名 + 操作入口）。
const double kPlayerBarLeftWidth = 300;
const double kPlayerBarLeftWidthCompact = 232;

/// 桌面底部播放栏：QQ 音乐 PC 式左/中/右三段布局，视觉沿用本项目主题。
///
/// - 左：封面/曲目信息（悬停浮出放大图标，点击进播放页）+ 喜欢/评论/下载/更多（窄窗只留喜欢）。
///   播放页内嵌时（[onCollapse] 非空）不展示封面，由最左「收起」键占据封面位置。
/// - 中：上层播放控制（居中，含播放模式、上一首、播放/暂停、下一首、音量气泡）+ 下层进度条（Expanded 吃满剩余宽度）。
/// - 右：音质 + 音效(?) + 桌面词(?) + 队列。
///
/// 无歌曲时保持占位布局（高度稳定，不随播放状态跳变）。
///
/// 同一组件同时服务两个入口，靠参数区分：
/// - 主界面常驻底栏（[DesktopShell]）：默认参数，浅色/深色主题原样。
/// - 全屏播放页底部（`LandscapePlayerContent`）：[overlayDark] 沉浸深色 +
///   [openPlayerPageEnabled] 关掉「再进一层播放页」+ [onCollapse] 最左收起键，
///   即 QQ 音乐 PC 正在播放页那种「内容之上、页面最底仍是那条常驻播放栏」。
class DesktopPlayerBar extends StatelessWidget {
  const DesktopPlayerBar({
    super.key,
    required this.player,
    required this.auth,
    this.onOpenPlayerPage,
    this.onOpenComment,
    this.onOpenArtist,
    this.onCollapse,
    this.openPlayerPageEnabled = true,
    this.overlayDark = false,
  });

  final PlayerController player;
  final AuthController auth;
  final VoidCallback? onOpenPlayerPage;

  /// 打开评论页。桌面由 shell 传入，推入内容区 Navigator（保留侧栏）；
  /// 未传时退回根 Navigator（全屏，移动端语义）。
  final ValueChanged<String>? onOpenComment;

  /// 打开歌手页。桌面由 shell 传入，推入内容区 Navigator（保留侧栏）；
  /// 未传时退回根 Navigator（全屏）。
  final ValueChanged<ArtistRef>? onOpenArtist;

  /// 最左侧「收起」按钮回调。非空时在最左渲染收起键（播放页用于返回主界面）。
  final VoidCallback? onCollapse;

  /// 是否允许点底栏空白/歌曲信息进入全屏播放页。
  ///
  /// 播放页底部复用本栏时必须置 false：否则点一下会在播放页上再叠一层播放页。
  final bool openPlayerPageEnabled;

  /// 沉浸深色：整条透明底 + 浅色前景，用于播放页的黑色封面背景之上。
  final bool overlayDark;

  void _openPlayerPage(BuildContext context) {
    if (!openPlayerPageEnabled) return;
    if (player.currentSong == null) return;
    if (onOpenPlayerPage != null) {
      onOpenPlayerPage!();
      return;
    }
    PlayerPageRoute.open(context, player: player, auth: auth);
  }

  /// 底栏空白/歌曲信息是否可点（进播放页）。
  bool get _barTappable => openPlayerPageEnabled && player.currentSong != null;

  @override
  Widget build(BuildContext context) {
    // 沉浸深色走局部 Theme 覆写：本栏内所有部件（含 PlayModeButton /
    // VolumePopoverButton 这些直接读 Theme 的共用件）都能拿到浅色前景，
    // 不必逐个透传颜色参数。
    final theme = overlayDark
        ? _overlayDarkBarTheme(Theme.of(context))
        : Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    // 播放页复用时底栏浮在黑色封面之上：整条透明，不再叠半透明黑底，
    // 与封面背景融为一体（QQ 音乐 PC 正在播放页观感）。
    final background = overlayDark
        ? Colors.transparent
        : (isDark ? const Color(0xFF1E2433) : Colors.white);
    final borderColor = overlayDark
        ? Colors.transparent
        : colorScheme.outlineVariant.withValues(alpha: .5);

    return Theme(
      data: theme,
      child: AnimatedBuilder(
        animation: player,
        builder: (context, _) {
          final song = player.currentSong;
          return GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: _barTappable ? () => _openPlayerPage(context) : null,
            child: MouseRegion(
              cursor: _barTappable
                  ? SystemMouseCursors.click
                  : SystemMouseCursors.basic,
              child: Container(
                height: 80,
                decoration: BoxDecoration(
                  color: background,
                  border: overlayDark
                      ? null
                      : Border(
                          top: BorderSide(color: borderColor, width: 1),
                        ),
                ),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final compact =
                        constraints.maxWidth < kPlayerBarCompactBreakpoint;
                    final leftWidth = compact
                        ? kPlayerBarLeftWidthCompact
                        : kPlayerBarLeftWidth;
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        if (onCollapse != null) ...[
                          const SizedBox(width: 6),
                          _CollapseButton(onPressed: onCollapse!),
                          const SizedBox(width: 10),
                        ] else
                          const SizedBox(width: 12),
                        // —— 左：歌曲信息 + 操作入口 ——
                        // 播放页内嵌态（onCollapse != null）不渲染封面：
                        // 页内已有封面大图，收起键顶替封面位置。
                        SizedBox(
                          width: leftWidth,
                          child: SongInfo(
                            player: player,
                            auth: auth,
                            song: song,
                            colorScheme: colorScheme,
                            onTap: _barTappable
                                ? () => _openPlayerPage(context)
                                : null,
                            onOpenComment: onOpenComment,
                            onOpenArtist: onOpenArtist,
                            showCover: onCollapse == null,
                          ),
                        ),
                        // —— 中：控制（上）+ 进度（下），Expanded 吃满剩余宽度 ——
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            // 紧凑点击目标：中间列是控制+进度双层叠放，默认 48px
                            // 点击目标会撑爆 80px 底栏，这里收成桌面鼠标友好的
                            // 小目标（保留图标尺寸，只收内边距）。
                            child: IconButtonTheme(
                              data: IconButtonThemeData(
                                style: IconButton.styleFrom(
                                  padding: EdgeInsets.zero,
                                  minimumSize: const Size(32, 32),
                                  tapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                ).copyWith(
                                  mouseCursor: WidgetStateProperty.resolveWith(
                                    (states) => states.contains(WidgetState.disabled)
                                        ? SystemMouseCursors.basic
                                        : SystemMouseCursors.click,
                                  ),
                                ),
                              ),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      PlayModeButton(player: player),
                                      const SizedBox(width: 20),
                                      IconButton(
                                        tooltip: '上一首',
                                        onPressed: song == null
                                            ? null
                                            : player.previous,
                                        icon: const Icon(
                                          Icons.skip_previous_rounded,
                                          size: 28,
                                        ),
                                        color: colorScheme.onSurface,
                                      ),
                                      const SizedBox(width: 20),
                                      IconButton(
                                        tooltip: player.isPlaying ? '暂停' : '播放',
                                        onPressed:
                                            player.isPreparing || song == null
                                            ? null
                                            : player.togglePlay,
                                        icon: Icon(
                                          player.isPlaying
                                              ? Icons.pause_circle_rounded
                                              : Icons.play_circle_rounded,
                                          size: 36,
                                        ),
                                        color: colorScheme.primary,
                                      ),
                                      const SizedBox(width: 20),
                                      IconButton(
                                        tooltip: '下一首',
                                        onPressed: song == null
                                            ? null
                                            : player.next,
                                        icon: const Icon(
                                          Icons.skip_next_rounded,
                                          size: 28,
                                        ),
                                        color: colorScheme.onSurface,
                                      ),
                                      const SizedBox(width: 20),
                                      VolumePopoverButton(
                                        key: const ValueKey(
                                          'desktop_volume_popover_button',
                                        ),
                                        player: player,
                                      ),
                                    ],
                                  ),
                                  // 进度区（拖拽中显示拖拽位置，松手 seek）。
                                  // 无歌时不渲染，但中间列仍由控制行撑住，底栏高度不变。
                                  if (song != null) ...[
                                    Center(
                                      child: ConstrainedBox(
                                        constraints: const BoxConstraints(
                                          maxWidth: 440,
                                        ),
                                        child: _ProgressBar(player: player),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        ),
                        // —— 右：功能区 ——
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // 音质切换
                            _AudioQualityButton(
                              key: const ValueKey(
                                'desktop_audio_quality_button',
                              ),
                              player: player,
                            ),
                            const SizedBox(width: 8),
                            // 音效（仅受支持平台渲染，不支持时不占位）
                            _EffectsButton(player: player),
                            // 桌面歌词开关（仅支持桌面歌词的平台渲染）
                            if (player.isDesktopLyricsSupported) ...[
                              _DesktopLyricsButton(player: player, song: song),
                              const SizedBox(width: 4),
                            ],
                            // 队列（PC：锚定在按钮上方的面板，替代移动端底部弹层）
                            Builder(
                              builder: (buttonContext) => IconButton(
                                tooltip: '播放队列',
                                onPressed: song == null
                                    ? null
                                    : () => showDesktopQueuePanel(
                                        buttonContext,
                                        player,
                                      ),
                                icon: const Icon(
                                  Icons.queue_music_rounded,
                                  size: 26,
                                ),
                                color: colorScheme.onSurface,
                              ),
                            ),
                            const SizedBox(width: 12),
                          ],
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// 沉浸深色底栏的局部主题：只把承载色翻成「深底浅字」，其余（primary 品牌色
/// 等）沿用原主题——播放页底栏仍要点出品牌金，不能整体反转。
///
/// 结果按 base 主题身份缓存：`Theme` 靠 `data` 的身份比较决定是否通知依赖，
/// 每次 copyWith 出新实例会让整条底栏的 Theme 依赖频繁重算；播放页会随播控
/// 状态重建本栏，这里返回同一实例即可零成本复用。
ThemeData _overlayDarkBarTheme(ThemeData base) {
  if (identical(_overlayDarkBaseCache, base) && _overlayDarkResultCache != null) {
    return _overlayDarkResultCache!;
  }
  final scheme = base.colorScheme;
  final result = base.copyWith(
    colorScheme: scheme.copyWith(
      brightness: Brightness.dark,
      onSurface: Colors.white,
      onSurfaceVariant: Colors.white.withValues(alpha: .74),
      outlineVariant: Colors.white.withValues(alpha: .22),
      surfaceContainerHighest: Colors.white.withValues(alpha: .18),
      // 进度条悬停时间气泡：深底栏上用浅底深字，与主界面底栏同款。
      inverseSurface: Colors.white,
      onInverseSurface: const Color(0xFF1B1B1B),
    ),
  );
  _overlayDarkBaseCache = base;
  _overlayDarkResultCache = result;
  return result;
}

ThemeData? _overlayDarkBaseCache;
ThemeData? _overlayDarkResultCache;

/// 播放页底栏最左「收起」键：收起播放页返回主界面。
///
/// 图标与封面悬停「展开」同一款对角双直角（QQ 音乐 PC 截图同款：
/// 右上 └ + 左下 ┐，顶点朝内、臂向外），仅以位置区分语义。
class _CollapseButton extends StatelessWidget {
  const _CollapseButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: '收起播放页',
      onPressed: onPressed,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 36, height: 36),
      icon: ExpandDetailIcon(
        size: 22,
        // 直接给色而非走 IconButton.color：便于单测断言颜色，
        // 也避免 IconTheme 解析层级带来的歧义。
        color: Theme.of(context).colorScheme.onSurface,
      ),
    );
  }
}

/// 左区：封面 + 曲名/歌手跑马灯 + 操作按钮行。
/// 悬停封面时浮出半透明蒙层 + 放大图标提示可进入播放页，点击进入。
///
/// [onTap] 为 null 表示当前场景不允许进播放页（如播放页底栏复用本栏时），
/// 此时封面不浮出放大提示、点击无响应。
///
/// [showCover] 为 false 时整体不渲染封面（播放页内嵌态：封面已在页内
/// 大图展示，底栏由最左「收起」键占据对应位置，与 QQ 音乐 PC 一致）。
@visibleForTesting
class SongInfo extends StatefulWidget {
  const SongInfo({
    super.key,
    required this.song,
    required this.colorScheme,
    required this.onTap,
    this.player,
    this.auth,
    this.onOpenComment,
    this.onOpenArtist,
    this.showCover = true,
  });

  final Song? song;
  final ColorScheme colorScheme;
  final VoidCallback? onTap;
  final PlayerController? player;
  final AuthController? auth;
  final ValueChanged<String>? onOpenComment;
  final ValueChanged<ArtistRef>? onOpenArtist;

  /// 是否渲染 48x48 封面（含悬停放大提示）。播放页内嵌态传 false。
  final bool showCover;

  @override
  State<SongInfo> createState() => _SongInfoState();
}


class _SongInfoState extends State<SongInfo> {
  bool _coverHovered = false;

  @override
  Widget build(BuildContext context) {
    final song = widget.song;
    final colorScheme = widget.colorScheme;
    final iconColor = colorScheme.onSurfaceVariant;
    // 不可进播放页时不展示「展开」提示，也不给点击反馈。
    final openable = song != null && widget.onTap != null;

    return LayoutBuilder(
      builder: (context, constraints) {
        Widget content = Row(
          children: [
            // 48x48 封面，悬停展示 ExpandDetailIcon 和 tooltip；
            // 播放页内嵌态不渲染，收起键顶替封面位置。
            if (widget.showCover) ...[
              MouseRegion(
                onEnter: (_) {
                  if (mounted) setState(() => _coverHovered = true);
                },
                onExit: (_) {
                  if (mounted) setState(() => _coverHovered = false);
                },
                child: Tooltip(
                  message: openable ? '展开歌曲详情页' : '',
                  child: InkWell(
                    onTap: openable ? widget.onTap : null,
                    // 单击展开歌曲详情页 → 手型；否则跟随整栏的 basic。
                    // InkWell 默认（adaptiveClickable）在桌面原生解析为
                    // basic 箭头，会顶掉外层整栏的手型区域。
                    mouseCursor: openable
                        ? SystemMouseCursors.click
                        : SystemMouseCursors.basic,
                    borderRadius: BorderRadius.circular(8),
                    child: SizedBox(
                      width: 48,
                      height: 48,
                      child: Stack(
                        children: [
                          Artwork(
                            url: song?.coverUrl,
                            size: 48,
                            borderRadius: 8,
                          ),
                          if (_coverHovered && openable)
                            Positioned.fill(
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: .45),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: const Center(
                                  child: ExpandDetailIcon(size: 20),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
            ],
            // 右侧纵向居中 Column：
            // Row 1: MarqueeText（歌名粗体 onSurface - 歌手常规 onSurfaceVariant）
            // Row 2: 操作按钮行 [LikeButton, SizedBox(width: 12), CommentButton, SizedBox(width: 12), SongMoreButton]
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: openable ? widget.onTap : null,
                    child: MouseRegion(
                      cursor: openable
                          ? SystemMouseCursors.click
                          : SystemMouseCursors.basic,
                      child: MarqueeText(
                        textSpan: TextSpan(
                          children: [
                            TextSpan(
                              text: song?.title ?? '尚未播放',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: song == null
                                    ? colorScheme.onSurfaceVariant
                                    : colorScheme.onSurface,
                              ),
                            ),
                            if (song != null && song.artist.isNotEmpty)
                              TextSpan(
                                text: ' - ${song.artist}',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.normal,
                                  color: colorScheme.onSurfaceVariant,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 2),
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {},
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _LikeButton(
                          auth: widget.auth,
                          song: song,
                          iconColor: iconColor,
                          activeColor: colorScheme.secondary,
                        ),
                        const SizedBox(width: 12),
                        PlayerCommentButton(
                          player: widget.player,
                          song: song,
                          iconSize: 18.0,
                          iconColor: iconColor,
                          onOpenComment: widget.onOpenComment,
                        ),
                        const SizedBox(width: 12),
                        SongMoreButton(
                          player: widget.player,
                          auth: widget.auth,
                          song: song,
                          onOpenArtist: widget.onOpenArtist,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        );

        if (!constraints.hasBoundedWidth) {
          content = SizedBox(width: kPlayerBarLeftWidth, child: content);
        }
        return content;
      },
    );
  }
}

/// 可选能力的安全读取：单测 fake 未实现这些成员时会抛，
/// 此时按“能力不可用”降级渲染而不是崩溃。
bool? _safeIsLiked(AuthController auth, Song song) {
  try {
    return auth.isLiked(song);
  } catch (_) {
    return null;
  }
}

dynamic _safeDownloadController(PlayerController player) {
  try {
    return player.downloadController;
  } catch (_) {
    return null;
  }
}

bool _safeIsAudioEffectsSupported(PlayerController player) {
  try {
    return player.isAudioEffectsSupported;
  } catch (_) {
    return false;
  }
}

dynamic _safeApi(PlayerController player) {
  try {
    return player.api;
  } catch (_) {
    return null;
  }
}

String _safePlaybackSpeedLabel(PlayerController player) {
  try {
    return player.playbackSpeedLabel;
  } catch (_) {
    return '1.0x';
  }
}

String? _safeSleepTimerSubtitle(PlayerController player) {
  try {
    if (player.isSleepTimerActive) {
      final rem = player.sleepTimerRemaining;
      final text = formatSleepRemaining(rem);
      return text.isNotEmpty ? '剩余 $text' : null;
    }
    if (player.isSleepFinishCurrentSong) {
      return '播完歌曲后停止';
    }
    return null;
  } catch (_) {
    return null;
  }
}

/// 桌面级联二级：倍速档位。
List<SongSheetAction> _speedSubmenu(PlayerController player) {
  final current = snapToPlaybackSpeed(player.playbackSpeed);
  return [
    for (final step in kPlaybackSpeedSteps)
      SongSheetAction(
        icon: Icons.speed_rounded,
        title: formatPlaybackSpeed(step),
        selected: step == current,
        onTap: () => player.setPlaybackSpeed(step),
      ),
    if (current != 1.0)
      SongSheetAction(
        icon: Icons.restart_alt_rounded,
        title: '恢复默认',
        onTap: () => player.setPlaybackSpeed(1.0),
      ),
  ];
}

/// 桌面级联二级：定时选项。
///
/// 语义：设 90 分钟后，到点是立刻暂停，还是等「当时正在播的那首」播完再停。
List<SongSheetAction> _sleepTimerSubmenu(PlayerController player) {
  final finishSong =
      player.isSleepFinishCurrentSong || player.sleepFinishCurrentSongOption;
  final isActive = player.isSleepTimerActive || player.isSleepFinishCurrentSong;

  SongSheetAction durationAction(String label, Duration d) => SongSheetAction(
    icon: Icons.schedule_rounded,
    title: label,
    onTap: () {
      final finish =
          player.isSleepFinishCurrentSong ||
          player.sleepFinishCurrentSongOption;
      if (finish) {
        player.setSleepTimerFinishSong(d);
      } else {
        player.setSleepTimer(d);
      }
    },
  );

  return [
    // 互斥单选：菜单上直接标出到点行为，避免用户猜。
    SongSheetAction(
      icon: Icons.pause_circle_outline_rounded,
      title: '到点立即暂停',
      tooltip: '定时一到就暂停，不等当前歌曲播完',
      selected: !finishSong,
      closeOnTap: false,
      onTap: () => player.updateSleepTimerOption(false),
    ),
    SongSheetAction(
      icon: Icons.lyrics_outlined,
      title: '到点后听完这首',
      tooltip: '例如定时 90 分钟：到点后等当时正在播的这首播完，再暂停',
      selected: finishSong,
      closeOnTap: false,
      onTap: () => player.updateSleepTimerOption(true),
    ),
    durationAction('15 分钟', const Duration(minutes: 15)),
    durationAction('30 分钟', const Duration(minutes: 30)),
    durationAction('45 分钟', const Duration(minutes: 45)),
    durationAction('60 分钟', const Duration(minutes: 60)),
    durationAction('90 分钟', const Duration(minutes: 90)),
    if (isActive)
      SongSheetAction(
        icon: Icons.timer_off_outlined,
        title: '关闭定时',
        danger: true,
        onTap: player.cancelSleepTimer,
      ),
  ];
}

class _LikeButton extends StatelessWidget {
  const _LikeButton({
    required this.auth,
    required this.song,
    required this.iconColor,
    required this.activeColor,
  });

  final AuthController? auth;
  final Song? song;
  final Color iconColor;
  final Color activeColor;
  static const double _iconSize = 20.0;

  @override
  Widget build(BuildContext context) {
    if (auth == null) {
      return IconButton(
        tooltip: '喜欢',
        onPressed: null,
        icon: const Icon(Icons.favorite_border_rounded),
        iconSize: _iconSize,
        color: iconColor,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: 28, height: 28),
      );
    }
    return AnimatedBuilder(
      animation: auth!,
      builder: (context, _) {
        final liked = song == null ? null : _safeIsLiked(auth!, song!);
        final likeEnabled =
            song != null && song!.source == SongSource.kugou && liked != null;
        final isLiked = liked == true;
        return IconButton(
          tooltip: isLiked ? '取消喜欢' : '喜欢',
          onPressed: !likeEnabled
              ? null
              : () => toggleLikeWithFeedback(auth!, song!),
          icon: Icon(
            isLiked
                ? Icons.favorite_rounded
                : Icons.favorite_border_rounded,
          ),
          iconSize: _iconSize,
          color: isLiked ? activeColor : iconColor,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints.tightFor(width: 28, height: 28),
        );
      },
    );
  }
}


@visibleForTesting
class SongMoreButton extends StatefulWidget {
  const SongMoreButton({
    super.key,
    required this.player,
    required this.auth,
    required this.song,
    this.iconSize = 18.0,
    this.onOpenArtist,
  });

  final PlayerController? player;
  final AuthController? auth;
  final Song? song;
  final double iconSize;
  final ValueChanged<ArtistRef>? onOpenArtist;

  @override
  State<SongMoreButton> createState() => _SongMoreButtonState();
}

class _SongMoreButtonState extends State<SongMoreButton> {
  bool _isOpen = false;

  Future<void> _openMenu(BuildContext buttonContext) async {
    final s = widget.song;
    if (s == null) return;
    final p = widget.player;
    final a = widget.auth;
    final ctrl = p == null ? null : _safeDownloadController(p);
    bool downloaded = false;
    if (ctrl != null) {
      try {
        downloaded = ctrl.isDownloaded(s);
      } catch (_) {
        downloaded = false;
      }
    }

    // 二级菜单与主菜单共用同一锚点（更多按钮上方）。
    final menuAnchor = anchorAbove(buttonContext);

    final actions = <SongSheetAction>[
      // 正在播放栏的「...」是当前歌曲：无需「下一首播放」（无意义）。
      if (a != null)
        SongSheetAction(
          icon: Icons.playlist_add_rounded,
          title: '添加到歌单',
          onTap: () => showAddToPlaylistSheet(
            context: buttonContext,
            auth: a,
            song: s,
          ),
        ),
      if (p != null)
        SongSheetAction(
          icon: Icons.auto_awesome_rounded,
          title: '试听高潮',
          subtitle: '播放歌曲高潮片段',
          onTap: () async {
            try {
              final ok = await p.playClimaxPreview();
              if (!ok) Toast.error('暂无高潮片段');
            } catch (_) {
              Toast.error('暂无高潮片段');
            }
          },
        ),
      if (p != null)
        SongSheetAction(
          icon: Icons.speed_rounded,
          title: '倍速播放',
          subtitle: _safePlaybackSpeedLabel(p),
          // 桌面走二级菜单；移动端仍弹底部面板。
          onTap: () => showPlaybackSpeedSheet(
            context: buttonContext,
            player: p,
          ),
          submenu: _speedSubmenu(p),
        ),
      if (p != null)
        SongSheetAction(
          icon: Icons.bedtime_rounded,
          title: '定时播放',
          subtitle: _safeSleepTimerSubtitle(p),
          onTap: () => showSleepTimerSheet(
            context: buttonContext,
            player: p,
          ),
          // 每次展开重新求值，保证单选勾选态最新。
          submenuBuilder: () => _sleepTimerSubmenu(p),
        ),
      if (ctrl != null && p != null)
        SongSheetAction(
          icon: downloaded
              ? Icons.download_done_rounded
              : Icons.download_rounded,
          title: downloaded ? '已下载' : '下载',
          onTap: () {
            if (downloaded) {
              Toast.info('歌曲已下载');
            } else {
              try {
                ctrl.download(s, p.audioQuality);
                Toast.success('已加入下载队列');
              } catch (_) {
                Toast.error('下载失败，请重试');
              }
            }
          },
        ),
      if (s.artist.isNotEmpty)
        SongSheetAction(
          icon: Icons.person_rounded,
          title: '查看歌手',
          onTap: () async {
            final openArtist = widget.onOpenArtist;
            final artist = s.artists.firstWhere(
              (item) => item.name.isNotEmpty,
              orElse: () => ArtistRef(
                id: '',
                name: s.artist,
              ),
            );
            if (openArtist != null && artist.name.isNotEmpty) {
              openArtist(artist);
              return;
            }
            final api = p == null ? null : _safeApi(p);
            if (api != null && a != null && p != null && artist.name.isNotEmpty) {
              // 兜底：未注入内容区回调时仍可打开（整窗全屏）。
              Navigator.of(buttonContext).push(
                MaterialPageRoute(
                  builder: (_) => ArtistDetailPage(
                    api: api,
                    auth: a,
                    artist: artist,
                    player: p,
                  ),
                ),
              );
            } else {
              await Clipboard.setData(
                ClipboardData(text: s.artist),
              );
              Toast.success('已复制歌手名：${s.artist}');
            }
          },
        ),
      SongSheetAction(
        icon: Icons.copy_rounded,
        title: '复制歌曲信息',
        onTap: () async {
          final text = '${s.title} - ${s.artist}';
          await Clipboard.setData(ClipboardData(text: text));
          Toast.success('已复制歌曲信息');
        },
      ),
    ];

    await showSongActionSheet(
      context: buttonContext,
      song: s,
      actions: actions,
      anchor: menuAnchor,
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final enabled = widget.song != null;
    final defaultColor = colorScheme.onSurfaceVariant;
    final activeColor = colorScheme.primary;
    final currentColor = !enabled
        ? defaultColor.withValues(alpha: 0.38)
        : (_isOpen ? activeColor : defaultColor);

    return Builder(
      builder: (buttonContext) {
        return IconButton(
          key: const ValueKey('desktop_song_more_button'),
          tooltip: '更多操作',
          iconSize: widget.iconSize,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints.tightFor(width: 28, height: 28),
          color: currentColor,
          onPressed: !enabled
              ? null
              : () async {
                  setState(() => _isOpen = true);
                  try {
                    await _openMenu(buttonContext);
                  } finally {
                    if (mounted) {
                      setState(() => _isOpen = false);
                    }
                  }
                },
          icon: Container(
            width: 18,
            height: 18,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: currentColor,
                width: 1.2,
              ),
            ),
            alignment: Alignment.center,
            child: Icon(
              Icons.more_horiz_rounded,
              size: 12,
              color: currentColor,
            ),
          ),
        );
      },
    );
  }
}

/// 右区：音效入口。仅受支持平台渲染，不支持时不占位。
class _EffectsButton extends StatelessWidget {
  const _EffectsButton({required this.player});

  final PlayerController player;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: player,
      builder: (context, _) {
        if (!_safeIsAudioEffectsSupported(player)) {
          return const SizedBox.shrink();
        }
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: '音效',
              onPressed: () =>
                  showAudioEffectsSheet(context: context, player: player),
              icon: const Icon(Icons.graphic_eq_rounded, size: 22),
              color: Theme.of(context).colorScheme.onSurface,
            ),
            const SizedBox(width: 4),
          ],
        );
      },
    );
  }
}

/// 右区：桌面歌词显隐开关（二态：开启/关闭）。
/// 锁定/解锁由悬浮窗胶囊、托盘或设置页负责；锁定时也可在此隐藏歌词，
/// 重新开启时沿用已持久化的锁定状态。
class _DesktopLyricsButton extends StatelessWidget {
  const _DesktopLyricsButton({required this.player, required this.song});

  final PlayerController player;
  final Song? song;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: player,
      builder: (context, _) {
        final enabled = player.desktopLyricsEnabled;
        final String tooltip;
        final IconData iconData;
        final Color color;
        final VoidCallback? onPressed;

        if (enabled) {
          tooltip = '关闭桌面歌词';
          iconData = Icons.lyrics_rounded;
          color = colorScheme.primary;
          onPressed = song == null
              ? null
              : () => player.setDesktopLyricsEnabled(false);
        } else {
          tooltip = '开启桌面歌词';
          iconData = Icons.lyrics_outlined;
          color = colorScheme.onSurface;
          onPressed = song == null
              ? null
              : () => player.setDesktopLyricsEnabled(true);
        }

        return IconButton(
          tooltip: tooltip,
          onPressed: onPressed,
          icon: Icon(iconData, size: 26),
          color: color,
        );
      },
    );
  }
}

class _ProgressBar extends StatefulWidget {
  const _ProgressBar({required this.player});

  final PlayerController player;

  @override
  State<_ProgressBar> createState() => _ProgressBarState();
}

class _ProgressBarState extends State<_ProgressBar> {
  double? _dragValue;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return ValueListenableBuilder<Duration>(
      valueListenable: widget.player.positionListenable,
      builder: (context, position, _) {
        final durationMs = widget.player.duration.inMilliseconds;
        final progress =
            _dragValue ??
            (durationMs > 0
                ? (position.inMilliseconds / durationMs).clamp(0.0, 1.0)
                : 0.0);
        final shownPosition = _dragValue != null && durationMs > 0
            ? Duration(milliseconds: (durationMs * _dragValue!).round())
            : position;
        return Row(
          children: [
            Text(
              formatDuration(shownPosition),
              style: TextStyle(
                fontSize: 11,
                fontFeatures: const [FontFeature.tabularFigures()],
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: 8),
            // 中间列 Expanded：进度条吃满左/右区之外的全部剩余宽度。
            // 悬停显示该位置时间气泡；拖拽中不显示（拖拽本身有位置反馈）。
            // 高度收到 28（桌面鼠标够用）：Slider 默认触控高度 48，
            // 双层叠放时会撑爆 80px 底栏。
            Expanded(
              child: SizedBox(
                height: 28,
                child: HoverTimeBubble(
                  duration: widget.player.duration,
                  showBubble: _dragValue == null && durationMs > 0,
                  formatDuration: formatDuration,
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      mouseCursor: const WidgetStatePropertyAll(
                        SystemMouseCursors.click,
                      ),
                      trackHeight: 3,
                      thumbShape: const RoundSliderThumbShape(
                        enabledThumbRadius: 6,
                      ),
                      overlayShape: const RoundSliderOverlayShape(
                        overlayRadius: 8,
                      ),
                      // 高潮起始标记（与播放页同一套轨道，多端数据同源）。
                      trackShape: ClimaxSliderTrackShape(
                        climaxStart: climaxStartFraction(
                          climax: widget.player.climax,
                          durationMs: durationMs,
                        ),
                        markerColor: colorScheme.primary.withValues(alpha: .45),
                      ),
                    ),
                    child: Slider(
                      value: progress,
                      onChanged: durationMs > 0
                          ? (value) => setState(() => _dragValue = value)
                          : null,
                      onChangeEnd: durationMs > 0
                          ? (value) async {
                              try {
                                await widget.player.seek(
                                  Duration(
                                    milliseconds: (durationMs * value).round(),
                                  ),
                                );
                              } catch (_) {
                                Toast.error('定位失败，请重试');
                              }
                              if (mounted) {
                                setState(() => _dragValue = null);
                              }
                            }
                          : null,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              formatDuration(widget.player.duration),
              style: TextStyle(
                fontSize: 11,
                fontFeatures: const [FontFeature.tabularFigures()],
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        );
      },
    );
  }
}

class _AudioQualityButton extends StatelessWidget {
  const _AudioQualityButton({super.key, required this.player});

  final PlayerController player;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: player,
      builder: (context, _) {
        final song = player.currentSong;
        final quality = player.audioQuality;
        final enabled = song != null;
        final colorScheme = Theme.of(context).colorScheme;
        final isLossless = quality == AudioQuality.lossless;
        final label = switch (quality) {
          AudioQuality.standard => '标准',
          AudioQuality.high => '高品',
          AudioQuality.lossless => '无损',
        };
        final tooltip = '音质：${quality.label} (${quality.badge}) - 点击切换';

        final Color foregroundColor;
        final Color borderColor;
        if (!enabled) {
          foregroundColor = colorScheme.onSurface.withValues(alpha: .38);
          borderColor = colorScheme.outlineVariant.withValues(alpha: .38);
        } else if (isLossless) {
          foregroundColor = colorScheme.primary;
          borderColor = colorScheme.primary.withValues(alpha: .6);
        } else {
          foregroundColor = colorScheme.onSurfaceVariant;
          borderColor = colorScheme.outlineVariant;
        }

        return Tooltip(
          message: tooltip,
          child: Material(
            color: Colors.transparent,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
              side: BorderSide(color: borderColor, width: 1),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              mouseCursor: enabled
                  ? SystemMouseCursors.click
                  : SystemMouseCursors.basic,
              hoverColor:
                  (isLossless ? colorScheme.primary : colorScheme.onSurface)
                      .withValues(alpha: 0.08),
              onTap: enabled
                  ? () async {
                      final anchor = anchorAboveRight(context);
                      final picked = await showAudioQualitySheet(
                        context: context,
                        selected: player.audioQuality,
                        title: '切换音质',
                        subtitle: '会重新加载当前歌曲并尽量保持播放进度',
                        anchor: anchor,
                      );
                      if (picked != null) {
                        await player.setAudioQuality(
                          picked,
                          reloadCurrent: true,
                        );
                        Toast.success('已切换到 ${picked.label}');
                      }
                    }
                  : null,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (isLossless) ...[
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 3,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: foregroundColor.withValues(alpha: .15),
                          borderRadius: BorderRadius.circular(3),
                        ),
                        child: Text(
                          'SQ',
                          style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.w900,
                            color: foregroundColor,
                            height: 1.1,
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                    ],
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: foregroundColor,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
