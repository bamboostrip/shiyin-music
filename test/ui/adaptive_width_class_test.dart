import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/ui/adaptive_layout.dart';

void main() {
  group('AdaptiveLayout.widthClassFor', () {
    test('边界值分级正确', () {
      expect(AdaptiveLayout.widthClassFor(599), WindowWidthClass.compact);
      expect(AdaptiveLayout.widthClassFor(600), WindowWidthClass.medium);
      expect(AdaptiveLayout.widthClassFor(839), WindowWidthClass.medium);
      expect(AdaptiveLayout.widthClassFor(840), WindowWidthClass.expanded);
      expect(AdaptiveLayout.widthClassFor(1199), WindowWidthClass.expanded);
      expect(AdaptiveLayout.widthClassFor(1200), WindowWidthClass.large);
      expect(AdaptiveLayout.widthClassFor(1599), WindowWidthClass.large);
      expect(AdaptiveLayout.widthClassFor(1600),
          WindowWidthClass.expandedDesktop);
    });
  });

  group('AdaptiveLayout.gridColumnsForWidth', () {
    test('低于网格起点返回 min', () {
      expect(AdaptiveLayout.gridColumnsForWidth(839), 2);
    });

    test('按最小项宽计算并夹在 [min, max]', () {
      // (840 - 32) ~/ 200 = 4
      expect(AdaptiveLayout.gridColumnsForWidth(840), 4);
      // 1600 宽下 (1600-32)~/200 = 7 → 被 max=6 截断
      expect(AdaptiveLayout.gridColumnsForWidth(1600), 6);
      // minItemWidth 放大后列数减少并落到 min
      expect(
        AdaptiveLayout.gridColumnsForWidth(840, minItemWidth: 500),
        2,
      );
      expect(
        AdaptiveLayout.gridColumnsForWidth(
          840,
          minItemWidth: 500,
          min: 3,
        ),
        3,
      );
    });

    test('medium 区间(600-839)恒返回 min（钉住早退守卫行为）', () {
      expect(AdaptiveLayout.gridColumnsForWidth(600), 2);
      expect(AdaptiveLayout.gridColumnsForWidth(700), 2);
      expect(AdaptiveLayout.gridColumnsForWidth(839), 2);
    });
  });
}
