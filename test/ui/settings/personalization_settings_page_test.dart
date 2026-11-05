import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyin_music/controllers/theme_controller.dart';
import 'package:shiyin_music/ui/app_theme.dart';
import 'package:shiyin_music/ui/background_crop.dart';
import 'package:shiyin_music/ui/form_factor.dart';
import 'package:shiyin_music/ui/pages/background_crop_page.dart';
import 'package:shiyin_music/ui/pages/personalization_settings_page.dart';
import 'package:shiyin_music/ui/widgets/background_crop_view.dart';

/// 「外观与个性化」二级页：外观模式 / 配色 / 背景 / 字体与布局四组齐全，
/// 移动形态才出现的横屏与车机模式开关，以及外观模式点击写回 controller。
void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    debugDesktopFormFactorOverride = null;
  });

  Future<void> pumpPage(WidgetTester tester, ThemeController theme) async {
    tester.view.physicalSize = const Size(1080, 20000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: PersonalizationSettingsPage(themeController: theme),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('四组设置齐全，外观模式三档都可选', (tester) async {
    final theme = ThemeController();
    await pumpPage(tester, theme);

    expect(find.text('外观模式'), findsOneWidget);
    expect(find.text('配色方案'), findsOneWidget);
    expect(find.text('全局背景图'), findsOneWidget);
    expect(find.text('字体与布局'), findsOneWidget);

    expect(find.text('跟随系统'), findsOneWidget);
    expect(find.text('浅色模式'), findsOneWidget);
    expect(find.text('深色模式'), findsOneWidget);
  });

  testWidgets('点击「深色模式」写回 controller 并刷新', (tester) async {
    final theme = ThemeController();
    await pumpPage(tester, theme);
    expect(theme.themeMode, ThemeMode.system);

    await tester.tap(find.text('深色模式'));
    await tester.pumpAndSettle();

    expect(theme.themeMode, ThemeMode.dark);
    expect(theme.themeModeLabel, '深色模式');
  });

  testWidgets('移动形态显示横屏/车机模式开关，默认不显示车机显示分节', (tester) async {
    debugDesktopFormFactorOverride = false;
    final theme = ThemeController();
    await pumpPage(tester, theme);

    expect(find.text('横屏模式'), findsOneWidget);
    expect(find.text('车机模式'), findsOneWidget);
    // 车机模式未开启时「车机显示」分节不出现。
    expect(find.text('车机显示'), findsNothing);
  });

  testWidgets('字体大小行显示当前档位', (tester) async {
    final theme = ThemeController();
    await pumpPage(tester, theme);

    expect(find.text('字体大小'), findsOneWidget);
    expect(find.text('标准'), findsOneWidget);
  });

  testWidgets('背景预览等比例解码，并跟随真实透明度与真实构图', (tester) async {
    final theme = ThemeController();
    await theme.load();
    await theme.setBackgroundImagePath('/tmp/not-exist-bg.jpg');
    await theme.setBackgroundOpacity(0.5);
    // 用一个非默认构图，确保断言不是「两边都是默认值」的恒真。
    const crop = BackgroundCrop(focusX: 0.3, focusY: 0.7, zoom: 2);
    await theme.setBackgroundCrop(crop);

    await pumpPage(tester, theme);

    // 标签与遮罩都取真实滑杆值，不再固定 15%。
    expect(find.text('预览效果（透明度 50%）'), findsOneWidget);

    // 预览与全局背景层共用等比例解码（fit），不能用 cacheWidth+cacheHeight
    // 把图压成正方形（issue #13「整体上传图片会变形」）；缩略图另取小上限。
    final preview = tester.widget<BackgroundCropView>(
      find.byType(BackgroundCropView),
    );
    expect(preview.image, isA<ResizeImage>());
    final resize = preview.image as ResizeImage;
    expect(resize.policy, ResizeImagePolicy.fit);
    expect(resize.width, backgroundPreviewDecodeCap);
    // 预览复用全局背景层的裁剪参数，两者观感一致。
    expect(preview.crop, crop);
  });

  testWidgets('已选择背景图时出现「调整背景位置」入口', (tester) async {
    final theme = ThemeController();
    await theme.load();

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: PersonalizationSettingsPage(themeController: theme),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('调整背景位置'), findsNothing);

    await theme.setBackgroundImagePath('/tmp/not-exist-bg.jpg');
    await tester.pumpAndSettle();
    expect(find.text('调整背景位置'), findsOneWidget);
  });

  testWidgets('点击「调整背景位置」打开裁剪页，取消后回到设置页', (tester) async {
    tester.view.physicalSize = const Size(420, 940);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final theme = ThemeController();
    await theme.load();
    await theme.setBackgroundImagePath('/tmp/not-exist-bg.jpg');

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: PersonalizationSettingsPage(themeController: theme),
      ),
    );
    await tester.pumpAndSettle();

    // 列表懒构建：先把入口滚进视口再点。
    await tester.scrollUntilVisible(
      find.text('调整背景位置'),
      120,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('调整背景位置'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(find.byType(BackgroundCropPage), findsOneWidget);

    await tester.tap(find.byTooltip('取消'));
    await tester.pump();
    // 转场动画约 450ms；裁剪页里没有无限动画（图片按缺失文件处理），可以直接等完。
    await tester.pump(const Duration(milliseconds: 900));
    await tester.pump();

    expect(find.byType(BackgroundCropPage), findsNothing);
    expect(find.text('选择背景图'), findsOneWidget);
  });

  testWidgets('裁剪页推到根 Navigator，不被内层导航的快捷键/侧栏波及', (tester) async {
    tester.view.physicalSize = const Size(420, 940);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final theme = ThemeController();
    await theme.load();
    await theme.setBackgroundImagePath('/tmp/not-exist-bg.jpg');

    final innerNavigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Navigator(
          key: innerNavigatorKey,
          onGenerateRoute: (_) => MaterialPageRoute(
            builder: (_) => PersonalizationSettingsPage(themeController: theme),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('调整背景位置'),
      120,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('调整背景位置'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(find.byType(BackgroundCropPage), findsOneWidget);
    // 桌面端设置页挂在内层内容 Navigator 里，它又在 AppShortcutScope /
    // DesktopShell.Shortcuts 子树内；裁剪页必须推到根 Navigator 才能避开
    // 空格播放、方向键 seek、Enter 叠播放页、点侧栏连弹编辑页这些穿透。
    expect(
      find.descendant(
        of: find.byKey(innerNavigatorKey),
        matching: find.byType(BackgroundCropPage),
      ),
      findsNothing,
    );

    await tester.tap(find.byTooltip('取消'));
    await tester.pumpAndSettle();
    expect(find.byType(BackgroundCropPage), findsNothing);
  });
}
