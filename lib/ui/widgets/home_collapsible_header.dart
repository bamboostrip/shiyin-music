import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show FloatingHeaderSnapConfiguration;
import 'package:flutter_svg/flutter_svg.dart';

import '../../controllers/auth_controller.dart';
import '../../controllers/player_controller.dart';
import '../../services/identify_service.dart';
import '../../services/music_api.dart';
import '../pages/identify_page.dart';
import '../pages/search_page.dart';

/// 页面层固定吸顶头视图：以普通 widget 形式渲染
/// [HomeCollapsibleHeaderDelegate] 的布局与绘制（搜索行淡出上移、标签栏
/// 吸顶、背景随收折渐显），但自身不参与任何滚动。
///
/// 用于「顶栏提升到 PageView 之上」的架构：三个 tab 的内容列表在下方
/// PageView 中横向切换，顶栏固定不动；收折进度由外部按当前 tab 的内容
/// 滚动 offset（切页动画中为相邻两 tab 的插值）计算后经 [shrinkOffset]
/// 传入。高度随收折从 maxExtent 收缩到 minExtent，与 sliver 版行为一致。
class HomeCollapsibleHeaderView extends StatelessWidget {
  const HomeCollapsibleHeaderView({
    super.key,
    required this.delegate,
    required this.shrinkOffset,
  });

  final HomeCollapsibleHeaderDelegate delegate;
  final double shrinkOffset;

  @override
  Widget build(BuildContext context) {
    final collapseRange = delegate.maxExtent - delegate.minExtent;
    final effective = shrinkOffset.clamp(0.0, collapseRange);
    return SizedBox(
      height: delegate.maxExtent - effective,
      child: delegate.build(context, effective, false),
    );
  }
}

/// 首页吸顶收折头部 Delegate。
///
/// 顶部展示搜索栏，下方展示胶囊标签栏。向下滚动时搜索栏平滑收折淡出，
/// 标签栏常驻吸顶。向上滚动时搜索栏平滑展开。
class HomeCollapsibleHeaderDelegate extends SliverPersistentHeaderDelegate {
  HomeCollapsibleHeaderDelegate({
    required this.api,
    required this.auth,
    required this.player,
    required this.sectionIndex,
    required this.onSectionChanged,
    this.pageTracker,
    this.onRefresh,
    this.onIdentifyTap,
    this.vsync,
    this.topPadding = 0.0,
    this.topMargin = 8.0,
    this.searchBarHeight = 36.0,
    this.tabBarHeight = 36.0,
    this.bottomPadding = 6.0,
    this.spacing = 8.0,
    this.pinnedTopOffset = 4.0,
  });

  final MusicApi api;
  final AuthController auth;
  final PlayerController player;
  final int sectionIndex;
  final ValueChanged<int> onSectionChanged;
  final VoidCallback? onIdentifyTap;

  /// 首页 PageView 的控制器：胶囊指示器直接监听它逐帧联动，
  /// 避免外部为每个像素触发整页 setState。
  final PageController? pageTracker;
  final Future<void> Function()? onRefresh;

  void _openIdentify(BuildContext context) {
    if (onIdentifyTap != null) {
      onIdentifyTap!();
      return;
    }
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => IdentifyPage(
          player: player,
          auth: auth,
          musicApi: api,
        ),
      ),
    );
  }

  /// 浮出吸附动画的 vsync：配合 SliverPersistentHeader 的 floating +
  /// NestedScrollView 的 floatHeaderSlivers，上滑浮现搜索栏后松手自动
  /// 完全展开。测试场景可不传（此时无吸附动画）。
  @override
  final TickerProvider? vsync;

  final double topPadding;
  final double topMargin;
  final double searchBarHeight;
  final double tabBarHeight;
  final double bottomPadding;
  final double spacing;
  final double pinnedTopOffset;

  @override
  double get minExtent =>
      topPadding + pinnedTopOffset + tabBarHeight + bottomPadding;

  @override
  double get maxExtent =>
      topPadding + topMargin + searchBarHeight + spacing + tabBarHeight + bottomPadding;

  @override
  FloatingHeaderSnapConfiguration? get snapConfiguration => vsync == null
      ? null
      : FloatingHeaderSnapConfiguration(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOutCubic,
        );

  @override
  bool shouldRebuild(covariant HomeCollapsibleHeaderDelegate oldDelegate) {
    return oldDelegate.sectionIndex != sectionIndex ||
        oldDelegate.pageTracker != pageTracker ||
        oldDelegate.vsync != vsync ||
        oldDelegate.topPadding != topPadding ||
        oldDelegate.topMargin != topMargin ||
        oldDelegate.pinnedTopOffset != pinnedTopOffset ||
        oldDelegate.onRefresh != onRefresh ||
        oldDelegate.onIdentifyTap != onIdentifyTap ||
        oldDelegate.searchBarHeight != searchBarHeight ||
        oldDelegate.tabBarHeight != tabBarHeight ||
        oldDelegate.bottomPadding != bottomPadding ||
        oldDelegate.spacing != spacing ||
        oldDelegate.api != api ||
        oldDelegate.auth != auth ||
        oldDelegate.player != player ||
        oldDelegate.onSectionChanged != onSectionChanged;
  }

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final progress = (maxExtent > minExtent)
        ? (shrinkOffset / (maxExtent - minExtent)).clamp(0.0, 1.0)
        : 0.0;

    final opacity = (1.0 - progress * 1.5).clamp(0.0, 1.0);
    final scaffoldBg = theme.scaffoldBackgroundColor;
    final isTransparent =
        scaffoldBg == Colors.transparent || scaffoldBg.a == 0;
    final effectiveBgColor = isTransparent
        ? (isDark ? const Color(0xFF06070A) : Colors.white)
            .withValues(alpha: 0.85 * progress)
        : scaffoldBg;

    final effectiveOffset = shrinkOffset.clamp(0.0, maxExtent - minExtent);

    // 拦截横向拖动：顶栏（搜索框 + 标签栏）是跨 tab 的"固定顶区"，
    // 按住它左右滑不应穿透到底层 PageView 触发切页——只有下方内容区
    // 可以横向滑动切页。子级 GestureDetector 的横向拖动识别器在手势
    // 竞技场中先于父级 PageView 的滚动识别器声明胜利；只声明横向，
    // 垂直滚动的收折/展开行为不受影响。
    return GestureDetector(
      onHorizontalDragStart: (_) {},
      child: ClipRect(
      child: Container(
        decoration: BoxDecoration(
          color: effectiveBgColor,
          border: Border(
            bottom: progress > 0
                ? BorderSide(
                    color: theme.colorScheme.outlineVariant
                        .withValues(alpha: 0.3 * progress),
                    width: 0.5,
                  )
                : BorderSide.none,
          ),
          boxShadow: progress > 0
              ? [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.05 * progress),
                    blurRadius: 4,
                    offset: const Offset(0, 2),
                  ),
                ]
              : null,
        ),
        child: Stack(
          children: [
            // 顶行：搜索框 + 线稿 Logo（点击 Logo 进入听歌识曲，随滚动平滑淡出并上移）
            Positioned(
              top: topPadding + topMargin - effectiveOffset,
              left: 16,
              right: 16,
              height: searchBarHeight,
              child: Opacity(
                opacity: opacity,
                child: IgnorePointer(
                  ignoring: progress >= 0.75,
                  child: Row(
                    children: [
                      Expanded(
                        child: HomeSearchBar(
                          api: api,
                          auth: auth,
                          player: player,
                          height: searchBarHeight,
                        ),
                      ),
                      const SizedBox(width: 14),
                      HomeBrandHeader(
                        onTap: IdentifyService.isSupported
                            ? () => _openIdentify(context)
                            : null,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            // 胶囊标签栏：收折后紧贴 topPadding + pinnedTopOffset 常驻吸顶
            Positioned(
              top: topPadding + topMargin + searchBarHeight + spacing - effectiveOffset,
              left: 0,
              right: 0,
              height: tabBarHeight,
              child: HomeCapsuleTabBar(
                selectedIndex: sectionIndex,
                pageTracker: pageTracker,
                onTabSelected: onSectionChanged,
                onRefresh: onRefresh,
                height: tabBarHeight,
              ),
            ),
          ],
        ),
        ),
      ),
    );
  }
}

/// 首页顶部品牌线稿 Logo（参考 QQ 音乐：无底色、无阴影，随主题变色；可点击进入听歌识曲）。
///
/// SVG 全部描边使用 currentColor，通过 colorFilter 整体着色：
/// 浅色模式下为深灰墨色，深色模式下为高亮白色。
class HomeBrandHeader extends StatelessWidget {
  const HomeBrandHeader({
    super.key,
    this.size = 26.0,
    this.onTap,
  });

  final double size;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final colorScheme = theme.colorScheme;

    final lineColor = isDark
        ? Colors.white.withValues(alpha: 0.92)
        : colorScheme.onSurface.withValues(alpha: 0.82);

    Widget icon = SizedBox(
      width: size,
      height: size,
      child: SvgPicture.asset(
        'lib/assets/logo_line.svg',
        width: size,
        height: size,
        colorFilter: ColorFilter.mode(lineColor, BlendMode.srcIn),
        semanticsLabel: '时音',
        placeholderBuilder: (_) => Icon(
          Icons.music_note_rounded,
          size: size,
          color: lineColor,
        ),
      ),
    );

    if (onTap != null) {
      return InkResponse(
        radius: size - 2,
        onTap: onTap,
        child: Tooltip(
          message: '听歌识曲',
          child: icon,
        ),
      );
    }

    return icon;
  }
}

/// 首页顶部搜索框组件（参考 QQ 音乐：整胶囊、提示文案居中、极浅底色）。
class HomeSearchBar extends StatelessWidget {
  const HomeSearchBar({
    super.key,
    this.api,
    this.auth,
    this.player,
    this.onTap,
    this.onIdentifyTap,
    this.height = 36.0,
    this.hintText = '搜索歌曲、歌手、专辑',
    this.margin,
  });

  final MusicApi? api;
  final AuthController? auth;
  final PlayerController? player;
  final VoidCallback? onTap;
  final VoidCallback? onIdentifyTap;
  final double height;
  final String hintText;
  final EdgeInsetsGeometry? margin;

  void _handleTap(BuildContext context) {
    if (onTap != null) {
      onTap!();
      return;
    }
    if (api != null && auth != null && player != null) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => SearchPage(api: api!, auth: auth!, player: player!),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    Widget content = Container(
      height: height,
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.07)
            : const Color(0xFFF3F4F6),
        borderRadius: BorderRadius.circular(height / 2),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(height / 2),
          onTap: () => _handleTap(context),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.search_rounded,
                  size: 16.5,
                  color: colorScheme.onSurfaceVariant.withValues(
                    alpha: isDark ? 0.65 : 0.5,
                  ),
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    hintText,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: colorScheme.onSurfaceVariant.withValues(
                            alpha: isDark ? 0.7 : 0.6,
                          ),
                          fontWeight: FontWeight.w400,
                          fontSize: 14,
                        ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    if (margin != null) {
      content = Padding(padding: margin!, child: content);
    }

    return content;
  }
}

/// 首页灵动胶囊标签栏组件。
class HomeCapsuleTabBar extends StatelessWidget {
  const HomeCapsuleTabBar({
    super.key,
    required this.selectedIndex,
    this.pageTracker,
    required this.onTabSelected,
    this.tabs = const ['推荐', '排行榜', '电台'],
    this.onRefresh,
    this.height = 36.0,
  });

  final int selectedIndex;

  /// 首页 PageView 的控制器：胶囊/文字随滑动逐帧联动，且重建范围
  /// 局限在本组件内（外部无需为滑动逐像素 setState 整页）。为 null 时
  /// 仅按 [selectedIndex] 静态定位。
  final PageController? pageTracker;
  final ValueChanged<int> onTabSelected;
  final List<String> tabs;
  final Future<void> Function()? onRefresh;
  final double height;

  static const _labelFontSize = 14.5;
  // 单侧内边距：文字宽度 + 2×13.5 ≈ 旧版 56/70px 的视觉宽度（scale 1.0）。
  static const _labelHPadding = 13.5;
  static const _tabGap = 6.0;

  double _resolvePage() {
    final controller = pageTracker;
    if (controller != null &&
        controller.hasClients &&
        controller.position.haveDimensions) {
      return (controller.page ?? selectedIndex.toDouble())
          .clamp(0.0, (tabs.length - 1).toDouble());
    }
    return selectedIndex.toDouble();
  }

  /// 按真实文字（含系统字体缩放）测量标签宽度：任意 tab 数量都安全，
  /// 旧实现按 3 个固定宽度硬编码，多 tab 会 RangeError、大字号会溢出。
  double _measureLabel(String label, TextScaler textScaler) {
    final painter = TextPainter(
      text: TextSpan(
        text: label,
        style: const TextStyle(
          fontSize: _labelFontSize,
          fontWeight: FontWeight.w800,
        ),
      ),
      textScaler: textScaler,
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width;
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final textScaler = MediaQuery.textScalerOf(context);
    final tabWidths = <double>[
      for (final label in tabs)
        _measureLabel(label, textScaler) + _labelHPadding * 2,
    ];
    final tabOffsets = <double>[0.0];
    for (var i = 0; i < tabWidths.length - 1; i++) {
      tabOffsets.add(tabOffsets[i] + tabWidths[i] + _tabGap);
    }
    final totalWidth = tabOffsets.last + tabWidths.last;

    const capsuleHeight = 30.0;
    final topOffset = (height - capsuleHeight) / 2;

    Widget buildBar(double p) {
      // 任意相邻两 tab 之间线性插值（p 已被 clamp 在 [0, tabs.length-1]）。
      final i = p.floor().clamp(0, tabs.length - 1);
      final next = (i + 1).clamp(0, tabs.length - 1);
      final t = (p - i).clamp(0.0, 1.0);
      final currentLeft = tabOffsets[i] + (tabOffsets[next] - tabOffsets[i]) * t;
      final currentWidth = tabWidths[i] + (tabWidths[next] - tabWidths[i]) * t;

      return SizedBox(
        width: totalWidth,
        height: height,
        child: Stack(
          children: [
            // 滑动背景胶囊（与手势实时联动）
            Positioned(
              left: currentLeft,
              top: topOffset,
              width: currentWidth,
              height: capsuleHeight,
              child: Container(
                decoration: BoxDecoration(
                  color: colorScheme.primary.withValues(
                    alpha: isDark ? 0.22 : 0.12,
                  ),
                  borderRadius: BorderRadius.circular(capsuleHeight / 2),
                  border: Border.all(
                    color: colorScheme.primary.withValues(alpha: 0.22),
                    width: 1.0,
                  ),
                ),
              ),
            ),
            // 标签文字
            Row(
              children: [
                for (var i = 0; i < tabs.length; i++) ...[
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => onTabSelected(i),
                    child: SizedBox(
                      width: tabWidths[i],
                      height: height,
                      child: Center(
                        child: Text(
                          tabs[i],
                          style: TextStyle(
                            fontSize: _labelFontSize,
                            fontWeight: (p - i).abs() < 0.5
                                ? FontWeight.w800
                                : FontWeight.w600,
                            color: Color.lerp(
                              colorScheme.onSurfaceVariant
                                  .withValues(alpha: 0.85),
                              colorScheme.primary,
                              (1.0 - (p - i).abs()).clamp(0.0, 1.0),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (i < tabs.length - 1) const SizedBox(width: _tabGap),
                ],
              ],
            ),
          ],
        ),
      );
    }

    final tracker = pageTracker;
    final Widget tabBar = tracker != null
        ? ListenableBuilder(
            listenable: tracker,
            builder: (context, _) => buildBar(_resolvePage()),
          )
        : buildBar(selectedIndex.toDouble());

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0),
      child: SizedBox(
        height: height,
        child: Row(
          children: [
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: tabBar,
              ),
            ),
            if (onRefresh != null)
              IconButton(
                tooltip: '刷新',
                icon: const Icon(Icons.refresh_rounded),
                iconSize: 20,
                color: colorScheme.onSurfaceVariant,
                visualDensity: VisualDensity.compact,
                onPressed: onRefresh,
              ),
          ],
        ),
      ),
    );
  }
}
