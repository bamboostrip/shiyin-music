import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyin_music/controllers/theme_controller.dart';
import 'package:shiyin_music/ui/form_factor.dart';
import 'package:shiyin_music/ui/settings/car_display_settings_section.dart';
import 'package:shiyin_music/ui/widgets/toast.dart';

/// 「车机显示」设置分节：缩放档位选择、上下安全留白滑杆、恢复默认。
///
/// 用真实 [ThemeController] + mock SharedPreferences 验证 UI 与 controller
/// 接线（含持久化写入），而非 fake 控制器。
Future<void> _pumpSection(WidgetTester tester, ThemeController theme) async {
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: Toast.navigatorKey,
      home: Scaffold(
        body: AnimatedBuilder(
          animation: theme,
          builder: (_, _) => SingleChildScrollView(
            child: CarDisplaySettingsSection(theme: theme),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<ThemeController> _loadedTheme() async {
  final theme = ThemeController();
  await theme.load();
  return theme;
}

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    // 本机（Windows）跑测试时 isDesktopFormFactor 恒 true，车机显示 getter
    // 会被桌面门控钳回中性值；测试内统一按移动形态（车机/平板路径）跑。
    debugDesktopFormFactorOverride = false;
  });

  tearDown(() {
    debugDesktopFormFactorOverride = null;
  });

  testWidgets('四个瓦片齐全，默认显示标准缩放与无额外留白', (tester) async {
    final theme = await _loadedTheme();
    await _pumpSection(tester, theme);

    expect(find.text('车机显示'), findsOneWidget);
    expect(find.text('界面缩放'), findsOneWidget);
    expect(find.text('顶部安全留白'), findsOneWidget);
    expect(find.text('底部安全留白'), findsOneWidget);
    expect(find.text('恢复默认车机显示'), findsOneWidget);

    // 中性默认值：缩放 100%、上下留白 0，恢复默认瓦片置灰。
    expect(theme.carDisplayScale, 1.0);
    expect(find.text('标准（100%）'), findsOneWidget);
    expect(find.text('0 dp · 不额外留白'), findsNWidgets(2));
    expect(find.text('当前已是默认设置'), findsOneWidget);
  });

  testWidgets('底部弹窗选择放大（115%）后写回 controller', (tester) async {
    final theme = await _loadedTheme();
    await _pumpSection(tester, theme);

    await tester.tap(find.text('界面缩放'));
    await tester.pumpAndSettle();

    // 五个档位文案齐全。
    expect(find.text('紧凑（80%）'), findsOneWidget);
    expect(find.text('略小（90%）'), findsOneWidget);
    expect(find.text('放大（115%）'), findsOneWidget);
    expect(find.text('特大（130%）'), findsOneWidget);
    expect(find.byType(BottomSheet), findsOneWidget);

    await tester.tap(find.text('放大（115%）'));
    await tester.pumpAndSettle();

    expect(find.byType(BottomSheet), findsNothing);
    expect(theme.carDisplayScale, 1.15);
    // 弹窗关闭后瓦片副标题即时刷新（AnimatedBuilder 重建）。
    expect(find.text('放大（115%）'), findsOneWidget);
  });

  testWidgets('顶部留白拖动只改本地值，点「完成」才提交并关闭弹窗', (tester) async {
    final theme = await _loadedTheme();
    await _pumpSection(tester, theme);

    await tester.tap(find.text('顶部安全留白'));
    await tester.pumpAndSettle();

    expect(
      find.text('车机状态栏悬浮在应用上方、系统未上报高度时，向下留出这段距离'),
      findsOneWidget,
    );
    expect(find.text('完成'), findsOneWidget);
    final slider = find.byType(Slider);
    expect(slider, findsOneWidget);

    await tester.drag(slider, const Offset(80, 0));
    await tester.pumpAndSettle();

    // 拖动期间不写 controller（避免弹窗自身随留白跳变）。
    expect(theme.carMarginTop, 0);

    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();

    expect(theme.carMarginTop, greaterThan(0));
    // 落点对齐 5dp 网格（divisions: 20）。
    expect(theme.carMarginTop % 5, 0);
    expect(find.byType(Slider), findsNothing);
    expect(find.textContaining('为顶部悬浮状态栏让位'), findsOneWidget);
    // 顶部留白不影响底部。
    expect(theme.carMarginBottom, 0);
  });

  testWidgets('底部留白点「完成」后提交到底部字段', (tester) async {
    final theme = await _loadedTheme();
    await _pumpSection(tester, theme);

    await tester.tap(find.text('底部安全留白'));
    await tester.pumpAndSettle();

    await tester.drag(find.byType(Slider), const Offset(60, 0));
    await tester.pumpAndSettle();
    expect(theme.carMarginBottom, 0);

    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();

    expect(theme.carMarginBottom, greaterThan(0));
    expect(theme.carMarginTop, 0);
    expect(find.textContaining('为底部悬浮条让位'), findsOneWidget);
  });

  testWidgets('恢复默认车机显示：复位缩放与留白并弹出 Toast', (tester) async {
    final theme = await _loadedTheme();
    await theme.setCarDisplayScale(1.15);
    await theme.setCarMarginTop(20);
    await theme.setCarMarginBottom(10);
    expect(theme.hasCustomCarDisplay, isTrue);

    await _pumpSection(tester, theme);
    expect(find.text('缩放 100%、上下留白 0'), findsOneWidget);

    await tester.tap(find.text('恢复默认车机显示'));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(theme.carDisplayScale, 1.0);
    expect(theme.carMarginTop, 0);
    expect(theme.carMarginBottom, 0);
    expect(theme.hasCustomCarDisplay, isFalse);

    // 复位后瓦片变为不可点并给出默认态文案。
    expect(find.text('当前已是默认设置'), findsOneWidget);
    expect(find.text('标准（100%）'), findsOneWidget);
    // Toast 文案存在且渲染不崩（>=3 个瓦片同屏时仍为唯一文本）。
    expect(find.text('已恢复默认车机显示'), findsOneWidget);

    // 等 Toast 自动消失，避免测试结束仍挂 Timer。
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
  });
}
