import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/ui/app_theme.dart';
import 'package:shiyin_music/ui/design_tokens.dart';

void main() {
  group('全局弹窗主题 (bottomSheetTheme)', () {
    test('亮色与暗色主题均注入 16px (AppRadius.lg) 优雅圆角，替代 M3 默认 28px', () {
      for (final theme in [AppTheme.light(), AppTheme.dark()]) {
        final sheetTheme = theme.bottomSheetTheme;
        expect(sheetTheme.shape, isA<RoundedRectangleBorder>());
        final shape = sheetTheme.shape! as RoundedRectangleBorder;
        final borderRadius = shape.borderRadius as BorderRadius;
        expect(borderRadius.topLeft, const Radius.circular(AppRadius.lg));
        expect(borderRadius.topRight, const Radius.circular(AppRadius.lg));
        expect(borderRadius.bottomLeft, Radius.zero);
        expect(borderRadius.bottomRight, Radius.zero);
        expect(sheetTheme.clipBehavior, Clip.antiAlias);
        expect(sheetTheme.dragHandleSize, const Size(36, 4));
      }
    });

    testWidgets('showModalBottomSheet 默认继承主题的 16px 顶部圆角', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () {
                    showModalBottomSheet<void>(
                      context: context,
                      builder: (_) => const SizedBox(height: 200),
                    );
                  },
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      final materialFinder = find.descendant(
        of: find.byType(BottomSheet),
        matching: find.byType(Material),
      );
      expect(materialFinder, findsWidgets);
      final material = tester.widget<Material>(materialFinder.first);
      final shape = material.shape as RoundedRectangleBorder;
      final borderRadius = shape.borderRadius as BorderRadius;
      expect(borderRadius.topLeft, const Radius.circular(AppRadius.lg));
      expect(borderRadius.topRight, const Radius.circular(AppRadius.lg));
    });
  });
}
