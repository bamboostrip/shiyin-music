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
    testWidgets('展示桌面级上下文弹窗且宽度约 236px，包含歌曲信息与关闭按钮', (tester) async {
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

      // 验证顶部歌曲简要信息（标题、歌手、关闭按钮）
      expect(find.text('晴天'), findsOneWidget);
      expect(find.text('周杰伦'), findsOneWidget);
      expect(find.byIcon(Icons.close_rounded), findsOneWidget);

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

    testWidgets('点击右上角关闭按钮仅关闭弹窗不触发任何 action', (tester) async {
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

      await tester.tap(find.byIcon(Icons.close_rounded));
      await tester.pumpAndSettle();

      expect(find.byType(Dialog), findsNothing);
      expect(actionTriggered, isFalse);
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
