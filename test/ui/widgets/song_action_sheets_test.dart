import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyin_music/controllers/theme_controller.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/ui/form_factor.dart';
import 'package:shiyin_music/ui/widgets/song_action_sheets.dart';

void main() {
  const testSong = Song(
    id: '101',
    title: '晴天',
    rawTitle: '周杰伦 - 晴天 [SQ]',
    artist: '周杰伦',
    hash: 'hash_qingtian_sq',
    albumName: '叶惠美',
    duration: Duration(minutes: 4, seconds: 29),
  );

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ThemeController();
  });

  tearDown(() {
    debugDesktopFormFactorOverride = null;
  });

  Widget buildHostWidget({
    required Size size,
    required List<SongSheetAction> actions,
    Song song = testSong,
    Offset? anchor,
  }) {
    return MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(size: size),
        child: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () {
                  showSongActionSheet(
                    context: context,
                    song: song,
                    actions: actions,
                    anchor: anchor,
                  );
                },
                child: const Text('Open Menu'),
              ),
            ),
          ),
        ),
      ),
    );
  }

  group('PC 桌面级紧凑菜单 (isDesktopFormFactor = true)', () {
    testWidgets('展示桌面级上下文弹窗且宽度约 236px，包含歌曲信息（无关闭按钮）', (tester) async {
      debugDesktopFormFactorOverride = true;
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      var nextPlayClicked = false;
      final actions = [
        SongSheetAction(
          icon: Icons.queue_music_rounded,
          title: '下一首播放',
          onTap: () => nextPlayClicked = true,
        ),
        SongSheetAction(
          icon: Icons.playlist_add_rounded,
          title: '添加到歌单',
          onTap: () {},
        ),
      ];

      await tester.pumpWidget(
        buildHostWidget(size: const Size(1280, 800), actions: actions),
      );

      await tester.tap(find.text('Open Menu'));
      await tester.pumpAndSettle();

      // 验证桌面弹窗已弹出（通过 Dialog 呈现）
      expect(find.byType(Dialog), findsOneWidget);

      // 验证弹窗宽度在 220~240px 范围内
      final containerFinder = find.descendant(
        of: find.byType(Dialog),
        matching: find.byWidgetPredicate(
          (w) => w is Container && w.constraints?.maxWidth == 236.0,
        ),
      );
      expect(containerFinder, findsOneWidget);

      // 验证顶部歌曲简要信息（标题、歌手）。
      expect(find.text('晴天'), findsOneWidget);
      expect(find.text('周杰伦'), findsOneWidget);
      // PC 上下文菜单规范：无 X 关闭按钮（点击菜单外/Esc 关闭）。
      expect(find.byIcon(Icons.close_rounded), findsNothing);

      // 验证操作项内容
      expect(find.text('下一首播放'), findsOneWidget);
      expect(find.text('添加到歌单'), findsOneWidget);
      expect(find.byIcon(Icons.queue_music_rounded), findsOneWidget);
      expect(find.byIcon(Icons.playlist_add_rounded), findsOneWidget);

      // 点击操作项：关闭弹窗并触发回调
      await tester.tap(find.text('下一首播放'));
      await tester.pumpAndSettle();

      expect(nextPlayClicked, isTrue);
      expect(find.byType(Dialog), findsNothing);
    });

    testWidgets('支持鼠标悬停（Hover）与手型光标', (tester) async {
      debugDesktopFormFactorOverride = true;
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      final actions = [
        SongSheetAction(
          icon: Icons.queue_music_rounded,
          title: '下一首播放',
          onTap: () {},
        ),
      ];

      await tester.pumpWidget(
        buildHostWidget(size: const Size(1280, 800), actions: actions),
      );

      await tester.tap(find.text('Open Menu'));
      await tester.pumpAndSettle();

      final actionFinder = find.text('下一首播放');
      expect(actionFinder, findsOneWidget);

      // 验证手型光标
      final mouseRegionFinder = find.ancestor(
        of: actionFinder,
        matching: find.byWidgetPredicate(
          (w) => w is MouseRegion && w.cursor == SystemMouseCursors.click,
        ),
      );
      expect(mouseRegionFinder, findsAtLeastNWidgets(1));

      // 模拟鼠标悬停
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      await gesture.moveTo(tester.getCenter(actionFinder));
      await tester.pumpAndSettle();

      // 验证 AnimatedContainer 悬停高亮
      final animatedContainer = tester.widget<AnimatedContainer>(
        find.ancestor(
          of: actionFinder,
          matching: find.byType(AnimatedContainer),
        ).first,
      );
      final decoration = animatedContainer.decoration as BoxDecoration?;
      expect(decoration?.color, isNot(Colors.transparent));

      await gesture.removePointer();
    });

    testWidgets('点击菜单外空白处关闭（light dismiss）且不触发任何 action', (tester) async {
      debugDesktopFormFactorOverride = true;
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      var actionTriggered = false;
      final actions = [
        SongSheetAction(
          icon: Icons.queue_music_rounded,
          title: '下一首播放',
          onTap: () => actionTriggered = true,
        ),
      ];

      await tester.pumpWidget(
        buildHostWidget(size: const Size(1280, 800), actions: actions),
      );

      await tester.tap(find.text('Open Menu'));
      await tester.pumpAndSettle();

      expect(find.byType(Dialog), findsOneWidget);

      // 点击弹窗外的空白处（右上角）：仅关闭，不触发 action。
      await tester.tapAt(const Offset(1260, 40));
      await tester.pumpAndSettle();

      expect(find.byType(Dialog), findsNothing);
      expect(actionTriggered, isFalse);
    });
    testWidgets('传入 anchor 时走锚定路由：不出现居中 Dialog，菜单宽 220 且不越界', (tester) async {
      debugDesktopFormFactorOverride = true;
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      final actions = [
        SongSheetAction(
          icon: Icons.queue_music_rounded,
          title: '下一首播放',
          onTap: () {},
        ),
        SongSheetAction(
          icon: Icons.playlist_add_rounded,
          title: '添加到歌单',
          onTap: () {},
        ),
      ];

      // 锚点在屏幕右下角：菜单应翻转并保留边距，而不是居中。
      await tester.pumpWidget(
        buildHostWidget(
          size: const Size(1280, 800),
          actions: actions,
          anchor: const Offset(1270, 780),
        ),
      );

      await tester.tap(find.text('Open Menu'));
      await tester.pumpAndSettle();

      expect(find.byType(Dialog), findsNothing);
      expect(find.text('晴天'), findsOneWidget);
      expect(find.text('下一首播放'), findsOneWidget);

      // 锚定面板宽 220（PC 规格 200~220），且整体位于屏幕边距内（翻转生效）。
      final positioned = tester.widgetList<Positioned>(
        find.byWidgetPredicate(
          (w) => w is Positioned && w.width != null && w.height != null,
        ),
      ).first;
      expect(positioned.width, 220);
      expect(positioned.left, greaterThanOrEqualTo(0));
      expect(positioned.top, greaterThanOrEqualTo(0));
      expect(positioned.left! + positioned.width!, lessThanOrEqualTo(1280));
      expect(positioned.top! + positioned.height!, lessThanOrEqualTo(800));

      // 点击菜单项后正常关闭。
      await tester.tap(find.text('下一首播放'));
      await tester.pumpAndSettle();
      expect(find.text('下一首播放'), findsNothing);
    });

    testWidgets('锚定菜单 barrier 视觉透明（light dismiss 不压暗背景）', (tester) async {
      debugDesktopFormFactorOverride = true;
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(
        buildHostWidget(
          size: const Size(1280, 800),
          actions: [
            SongSheetAction(
              icon: Icons.queue_music_rounded,
              title: '下一首播放',
              onTap: () {},
            ),
          ],
          anchor: const Offset(400, 300),
        ),
      );

      await tester.tap(find.text('Open Menu'));
      await tester.pumpAndSettle();

      // PC 桌面惯例：右键菜单不出现半透明遮罩（QQ 音乐/网易云/系统
      // 右键菜单均无压暗效果），仅以透明 barrier 承接点击外部关闭。
      final route = ModalRoute.of(
        tester.element(find.text('下一首播放')),
      );
      expect(route?.barrierColor, Colors.transparent);
      expect(route?.barrierDismissible, isTrue);
    });

    for (final scale in [1.0, 1.5, 2.0]) {
      testWidgets('锚定菜单 textScale=$scale 条目不溢出（行高随字体缩放）',
          (tester) async {
        debugDesktopFormFactorOverride = true;
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() => tester.view.resetPhysicalSize());

        await tester.pumpWidget(
          MediaQuery(
            data: const MediaQueryData(size: Size(1280, 800)).copyWith(
              textScaler: TextScaler.linear(scale),
            ),
            child: MaterialApp(
              home: Scaffold(
                body: Builder(
                  builder: (context) => Center(
                    child: ElevatedButton(
                      onPressed: () {
                        showSongActionSheet(
                          context: context,
                          song: testSong,
                          anchor: const Offset(400, 300),
                          actions: [
                            SongSheetAction(
                              icon: Icons.queue_music_rounded,
                              title: '下一首播放',
                              onTap: () {},
                            ),
                            SongSheetAction(
                              icon: Icons.playlist_add_rounded,
                              title: '添加到歌单',
                              onTap: () {},
                            ),
                            SongSheetAction(
                              icon: Icons.person_rounded,
                              title: '查看歌手',
                              onTap: () {},
                            ),
                          ],
                        );
                      },
                      child: const Text('Open Menu'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );

        await tester.tap(find.text('Open Menu'));
        await tester.pumpAndSettle(const Duration(seconds: 1));

        expect(tester.takeException(), isNull);
        expect(find.text('下一首播放'), findsOneWidget);
      });
    }

    testWidgets('桌面菜单文字无黄色下划线（decoration 为 none）', (tester) async {
      debugDesktopFormFactorOverride = true;
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(
        buildHostWidget(
          size: const Size(1280, 800),
          actions: [
            SongSheetAction(
              icon: Icons.queue_music_rounded,
              title: '下一首播放',
              onTap: () {},
            ),
            SongSheetAction(
              icon: Icons.playlist_add_rounded,
              title: '添加到歌单',
              onTap: () {},
            ),
          ],
          anchor: const Offset(400, 300),
        ),
      );

      await tester.tap(find.text('Open Menu'));
      await tester.pumpAndSettle();

      for (final element in tester.elementList(find.byType(RichText))) {
        final richText = element.widget as RichText;
        final style = richText.text.style;
        expect(
          style?.decoration,
          isNot(TextDecoration.underline),
          reason: '菜单文本不应包含下划线（避免无 Material 时出现黄色双下划线）',
        );
      }
    });
  });

  group('移动端形态保持 (isDesktopFormFactor = false)', () {
    testWidgets('竖屏形态下唤起底部弹窗 (ModalBottomSheet)，不使用 PC 桌面 Dialog', (tester) async {
      debugDesktopFormFactorOverride = false;
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      final actions = [
        SongSheetAction(
          icon: Icons.queue_music_rounded,
          title: '下一首播放',
          onTap: () {},
        ),
      ];

      await tester.pumpWidget(
        buildHostWidget(size: const Size(400, 800), actions: actions),
      );

      await tester.tap(find.text('Open Menu'));
      await tester.pumpAndSettle();

      // 移动端应使用 BottomSheet，而不是桌面 Dialog
      expect(find.byType(Dialog), findsNothing);
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.text('下一首播放'), findsOneWidget);
    });

    testWidgets('车机横屏模式下唤起车机左侧滑入弹窗', (tester) async {
      debugDesktopFormFactorOverride = false;
      await ThemeController.instance.setCarModeEnabled(true);
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      final actions = [
        SongSheetAction(
          icon: Icons.queue_music_rounded,
          title: '下一首播放',
          onTap: () {},
        ),
      ];

      await tester.pumpWidget(
        buildHostWidget(size: const Size(1280, 800), actions: actions),
      );

      await tester.tap(find.text('Open Menu'));
      await tester.pumpAndSettle();

      // 车机模式应是左侧 320 宽度的车机弹窗，包含 GridView
      expect(find.byType(Dialog), findsNothing);
      expect(find.byType(GridView), findsOneWidget);
      expect(find.text('下一首播放'), findsOneWidget);
    });
  });
}
