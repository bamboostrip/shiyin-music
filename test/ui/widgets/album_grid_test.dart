import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/ui/widgets/album_grid.dart';

ArtistAlbum _album(int i) => ArtistAlbum(
      id: 'album_$i',
      name: '专辑名称$i',
      coverUrl: null, // 测试中不触发网络图片加载
      publishDate: '2001-09-14',
    );

List<ArtistAlbum> _albums(int count) => List.generate(count, _album);

Future<void> _pump(
  WidgetTester tester, {
  required List<ArtistAlbum> albums,
  required double width,
  ValueChanged<ArtistAlbum>? onTap,
}) async {
  // 测试默认表面为 800x600，这里按用例需要的窗口宽度铺满视口。
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: CustomScrollView(
          slivers: [
            AlbumSliverGridSection(albums: albums, onTap: onTap ?? (_) {}),
          ],
        ),
      ),
    ),
  );
}

int _columnCountOf(WidgetTester tester) {
  final grid = tester.widget<SliverGrid>(find.byType(SliverGrid));
  final delegate = grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
  return delegate.crossAxisCount;
}

void main() {
  group('albumGridColumns 纯函数', () {
    test('按 ~168 目标列宽取整', () {
      expect(albumGridColumns(700), 4); // 700 / 168 = 4.16
      expect(albumGridColumns(900), 5); // 5.35
      expect(albumGridColumns(1200), 7); // 7.14
      expect(albumGridColumns(1344), 8); // 恰好 8
    });

    test('clamp 在 4~8', () {
      expect(albumGridColumns(0), 4);
      expect(albumGridColumns(-100), 4);
      expect(albumGridColumns(100), 4); // 0.59 → 下限 4
      expect(albumGridColumns(840), 5);
      expect(albumGridColumns(2000), 8); // 11.9 → 上限 8
      expect(albumGridColumns(99999), 8);
    });

    test('可自定义目标列宽与上下限', () {
      // 600 / 200 = 3 → clamp(4, 8) 下限 4
      expect(albumGridColumns(600, targetCellWidth: 200), 4);
      // 1344 / 336 = 4
      expect(albumGridColumns(1344, targetCellWidth: 336), 4);
      // 600 / 168 = 3.57 → 自定义上下限 2~6 时取 3
      expect(
        albumGridColumns(600, minColumns: 2, maxColumns: 6),
        3, // 600 / 168 = 3.57
      );
    });
  });

  group('albumGridCellExtent 纯函数', () {
    test('单元格高度 = 方形封面宽 + 文本块固定高度', () {
      expect(albumGridCellExtent(0), 64);
      expect(albumGridCellExtent(182.5), closeTo(246.5, 0.001));
    });
  });

  group('AlbumSliverGridSection', () {
    testWidgets('渲染标题与专辑卡片，列数随宽度自适应', (tester) async {
      await _pump(tester, albums: _albums(8), width: 1200);

      expect(find.text('专辑 8'), findsOneWidget);
      // 1200 宽 → 内容宽 1164 → floor(1164/168) = 6 列
      expect(_columnCountOf(tester), 6);
      expect(find.text('专辑名称0'), findsOneWidget);
      expect(find.text('2001-09-14'), findsNWidgets(8));
    });

    testWidgets('列数下限 4（窄窗口）与上限 8（超宽窗口）', (tester) async {
      await _pump(tester, albums: _albums(4), width: 600);
      await tester.pump();
      // 600 宽 → 内容 564 → floor(564/168) = 3 → clamp 下限 4
      expect(_columnCountOf(tester), 4);

      await _pump(tester, albums: _albums(4), width: 3000);
      await tester.pump();
      // 3000 宽 → 内容 2964 → floor = 17 → clamp 上限 8
      expect(_columnCountOf(tester), 8);
    });

    testWidgets('多行网格：超出列数的专辑换行到下一行', (tester) async {
      await _pump(tester, albums: _albums(8), width: 1200);

      final first = tester.getTopLeft(find.text('专辑名称0'));
      final seventh = tester.getTopLeft(find.text('专辑名称6'));
      expect(seventh.dy, greaterThan(first.dy)); // 7 张换行到第二行
      expect(seventh.dx, closeTo(first.dx, 0.5)); // 与第一列对齐
    });

    testWidgets('点击专辑回调对应专辑', (tester) async {
      ArtistAlbum? tapped;
      await _pump(tester, albums: _albums(2), width: 1200, onTap: (album) => tapped = album);

      await tester.tap(find.text('专辑名称1'));
      await tester.pump();
      expect(tapped?.id, 'album_1');
    });

    testWidgets('空专辑列表不崩溃（仅渲染标题）', (tester) async {
      await _pump(tester, albums: const [], width: 1200);

      expect(tester.takeException(), isNull);
      expect(find.text('专辑 0'), findsOneWidget);
      expect(find.byType(SliverGrid), findsOneWidget);
      expect(find.text('专辑名称0'), findsNothing);
    });
  });
}
