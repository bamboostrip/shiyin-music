import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/ui/app_theme.dart';
import 'package:shiyin_music/ui/widgets/theme_mode_selector.dart';

/// 外观模式三档选择器：深浅两套主题下都要渲染三档并正确回传点击档位。
Future<void> _pumpSelector(
  WidgetTester tester, {
  required ThemeData theme,
  required ThemeMode currentMode,
  required ValueChanged<ThemeMode> onChanged,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: Scaffold(
        body: ThemeModeSelector(currentMode: currentMode, onChanged: onChanged),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('浅色主题下三档齐全，点击「深色模式」回传 ThemeMode.dark', (tester) async {
    expect(themeModeOptions.length, 3);

    final tapped = <ThemeMode>[];
    await _pumpSelector(
      tester,
      theme: AppTheme.light(),
      currentMode: ThemeMode.system,
      onChanged: tapped.add,
    );

    expect(find.text('跟随系统'), findsOneWidget);
    expect(find.text('浅色模式'), findsOneWidget);
    expect(find.text('深色模式'), findsOneWidget);
    expect(tapped, isEmpty);

    await tester.tap(find.text('深色模式'));
    await tester.pump();

    expect(tapped, [ThemeMode.dark]);
  });

  testWidgets('深色主题下同样渲染三档，点击「浅色模式」回传 ThemeMode.light', (tester) async {
    final tapped = <ThemeMode>[];
    await _pumpSelector(
      tester,
      theme: AppTheme.dark(),
      currentMode: ThemeMode.dark,
      onChanged: tapped.add,
    );

    expect(find.text('跟随系统'), findsOneWidget);
    expect(find.text('浅色模式'), findsOneWidget);
    expect(find.text('深色模式'), findsOneWidget);
    expect(find.byType(ThemeModeSelector), findsOneWidget);

    await tester.tap(find.text('浅色模式'));
    await tester.pump();

    expect(tapped, [ThemeMode.light]);
  });
}
