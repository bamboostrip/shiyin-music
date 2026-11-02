import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyin_music/controllers/theme_controller.dart';
import 'package:shiyin_music/ui/app_theme.dart';
import 'package:shiyin_music/ui/settings/personalization_settings_section.dart';

/// 设置页「个性化」分节中的「外观模式」入口。
///
/// 用真实 [ThemeController]（不 load，默认跟随系统）+ 浅色主题验证瓦片
/// 文案与点击回调；外层 AnimatedBuilder 与 settings_page 的接线方式一致。
Future<void> _pumpSection(
  WidgetTester tester,
  ThemeController theme, {
  required VoidCallback onSelectThemeMode,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(
        body: SingleChildScrollView(
          child: AnimatedBuilder(
            animation: theme,
            builder: (_, _) => PersonalizationSettingsSection(
              theme: theme,
              showOrientationTiles: false,
              onSelectFontScale: () {},
              onSelectThemeMode: onSelectThemeMode,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('「外观模式」瓦片存在，副标题为「跟随系统」并转发点击', (tester) async {
    final theme = ThemeController();
    var tapped = false;
    await _pumpSection(tester, theme, onSelectThemeMode: () => tapped = true);

    // 标题精确命中「外观模式」；「皮肤与背景」副标题含同样四字但为整串文案，
    // 不会与标题混淆。
    expect(find.text('外观模式'), findsOneWidget);
    expect(find.text('外观模式、配色方案与自定义全局背景图'), findsOneWidget);
    // 副标题即当前模式标签（默认跟随系统）。
    expect(find.text('跟随系统'), findsOneWidget);
    expect(theme.themeModeLabel, '跟随系统');

    await tester.ensureVisible(find.text('外观模式'));
    await tester.tap(find.text('外观模式'));
    await tester.pumpAndSettle();

    expect(tapped, isTrue);
  });

  testWidgets('控制器切换后副标题跟随刷新（与设置页 AnimatedBuilder 接线一致）', (tester) async {
    final theme = ThemeController();
    await _pumpSection(tester, theme, onSelectThemeMode: () {});
    expect(find.text('跟随系统'), findsOneWidget);

    await theme.setThemeMode(ThemeMode.dark);
    await tester.pumpAndSettle();

    expect(find.text('深色模式'), findsOneWidget);
    expect(find.text('跟随系统'), findsNothing);
  });
}
