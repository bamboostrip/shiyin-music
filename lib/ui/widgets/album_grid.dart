import 'package:flutter/material.dart';

import '../../models/music_models.dart';
import '../design_tokens.dart';
import 'artwork.dart';

/// 专辑网格目标列宽（逻辑像素）：对齐 QQ 音乐 PC 歌手页的单元格尺度。
const double kAlbumGridTargetCellWidth = 168;

/// 专辑网格列数下限 / 上限。
const int kAlbumGridMinColumns = 4;
const int kAlbumGridMaxColumns = 8;

/// 根据可用宽度计算专辑网格列数（纯函数，便于单测）。
///
/// 规则（PC 基准 = QQ 音乐 PC 歌手页）：`(可用宽 / ~168).clamp(4, 8)`，
/// 列数随窗口宽度自适应；宽度异常（<= 0）时退回下限，保证不产生 0 列。
int albumGridColumns(
  double availableWidth, {
  double targetCellWidth = kAlbumGridTargetCellWidth,
  int minColumns = kAlbumGridMinColumns,
  int maxColumns = kAlbumGridMaxColumns,
}) {
  assert(minColumns > 0, 'minColumns 必须为正数');
  assert(minColumns <= maxColumns, 'minColumns 不能大于 maxColumns');
  assert(targetCellWidth > 0, 'targetCellWidth 必须为正数');
  if (availableWidth <= 0) return minColumns;
  return (availableWidth / targetCellWidth).floor().clamp(minColumns, maxColumns);
}

/// 专辑区网格单元格的固定高度（纯函数，便于单测）。
///
/// 单元格 = 方形圆角封面 + 间距 + 专辑名（至多 2 行，显式行高）+
/// 发行日期（1 行，显式行高）。用固定像素高度而非 childAspectRatio，
/// 避免不同列宽下文字溢出。
double albumGridCellExtent(double cellWidth) => cellWidth + 64;

/// 专辑网格横向 / 纵向间距。
const double _kAlbumGridSpacing = 14;

/// 根据可用宽度自适应计算专辑网格列数（支持移动端与桌面端）。
///
/// - contentWidth < 300: 2 列（极窄屏）
/// - 300 <= contentWidth <= 500: 3 列（手机竖屏基准，卡片宽度约 105~120dp）
/// - contentWidth > 500: 调用 [albumGridColumns]，4~8 列自适应（桌面/平板/宽屏）
int resolveAlbumGridColumns(double contentWidth) {
  if (contentWidth < 300) {
    return 2;
  }
  if (contentWidth <= 500) {
    return 3;
  }
  return albumGridColumns(contentWidth);
}

/// 专辑区：标题 + 响应式网格，以 sliver 形式嵌入页面
/// [CustomScrollView]（支持移动端与桌面端纵向滚动）。
///
/// 列数随可用宽度自适应（手机竖屏 3 列，桌面端 4~8 列）；
/// 滚动交给外层页面纵向滚动处理。
class AlbumSliverGridSection extends StatelessWidget {
  const AlbumSliverGridSection({
    super.key,
    required this.albums,
    required this.onTap,
    this.sectionSidePadding = 18,
  });

  final List<ArtistAlbum> albums;
  final ValueChanged<ArtistAlbum> onTap;

  /// 区块两侧外边距，桌面端默认 18px，移动端可设为 16px。
  final double sectionSidePadding;

  @override
  Widget build(BuildContext context) {
    return SliverLayoutBuilder(
      builder: (context, constraints) {
        final side = sectionSidePadding;
        final contentWidth = constraints.crossAxisExtent - side * 2;
        final columns = resolveAlbumGridColumns(contentWidth);
        final spacing = columns > 1 ? _kAlbumGridSpacing : 0.0;
        final cellWidth =
            ((contentWidth - spacing * (columns - 1)) / columns)
                .clamp(0.0, double.infinity);
        return SliverMainAxisGroup(
          slivers: [
            // section 标题（“专辑 20”），样式与改造前完全一致。
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(side, 8, side, 8),
                child: Text(
                  '专辑 ${albums.length}',
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.w900),
                ),
              ),
            ),
            SliverPadding(
              padding: EdgeInsets.fromLTRB(side, 12, side, 8),
              sliver: SliverGrid(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  crossAxisSpacing: _kAlbumGridSpacing,
                  mainAxisSpacing: _kAlbumGridSpacing,
                  mainAxisExtent: albumGridCellExtent(cellWidth),
                ),
                delegate: SliverChildBuilderDelegate(
                  childCount: albums.length,
                  (context, index) {
                    final album = albums[index];
                    return MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: AlbumGridCard(
                        album: album,
                        onTap: () => onTap(album),
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 专辑网格卡片：方形圆角封面 + 专辑名（1~2 行省略）+ 发行日期。
///
/// 内容与移动端横轨卡片保持同构，宽度随网格列宽自适应。
class AlbumGridCard extends StatelessWidget {
  const AlbumGridCard({super.key, required this.album, required this.onTap});

  final ArtistAlbum album;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.md),
            child: AspectRatio(
              aspectRatio: 1,
              child: Artwork(url: album.coverUrl, size: double.infinity),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            album.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 13,
              height: 1.35,
            ),
          ),
          if (album.publishDate case final date?)
            Text(
              date,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                height: 1.35,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }
}
