import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyin_music/controllers/theme_controller.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/ui/form_factor.dart';
import 'package:shiyin_music/ui/widgets/artwork.dart';
import 'package:shiyin_music/ui/widgets/song_action_sheets.dart';
import 'package:shiyin_music/ui/widgets/song_share.dart';
import 'package:shiyin_music/ui/widgets/toast.dart';

/// 歌曲分享：文案纯函数 + 移动端/车机/桌面三端入口共用同一剪贴板文案。
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
  const testSongWithoutAlbum = Song(
    id: '102',
    title: '稻香',
    artist: '周杰伦',
    hash: 'hash_daoxiang',
  );

  final actions = <SongSheetAction>[
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

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ThemeController();
  });

  tearDown(() async {
    debugDesktopFormFactorOverride = null;
    // 车机用例会打开车机模式：复位，避免污染同文件后续用例。
    await ThemeController.instance.setCarModeEnabled(false);
  });

  /// 拦截 Clipboard.setData（不依赖真实平台剪贴板），返回最近一次写入文本。
  ///
  /// 统一在用例内调用，tearDown 时恢复平台通道 handler，避免污染其它用例。
  String? Function() installClipboardSpy(WidgetTester tester) {
    String? copiedText;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copiedText = (call.arguments as Map)['text'] as String?;
      }
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    });
    return () => copiedText;
  }

  /// 唤起歌曲操作弹窗/菜单的最小宿主（按钮位于页面中心）。
  Widget buildSheetHost({
    required Size size,
    Song song = testSong,
    Offset? anchor,
    bool attachToastNavigator = false,
  }) {
    return MaterialApp(
      navigatorKey: attachToastNavigator ? Toast.navigatorKey : null,
      home: MediaQuery(
        data: MediaQueryData(size: size),
        child: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () => showSongActionSheet(
                  context: context,
                  song: song,
                  actions: actions,
                  anchor: anchor,
                ),
                child: const Text('Open Menu'),
              ),
            ),
          ),
        ),
      ),
    );
  }

  group('分享文案纯函数 buildSongShareText', () {
    test('有专辑：歌名/歌手/专辑与品牌行按固定格式拼接', () {
      expect(
        buildSongShareText(testSong),
        '🎵 推荐歌曲：《晴天》 - 周杰伦（专辑：叶惠美）\n来自 时音',
      );
    });

    test('无专辑（albumName 为 null）：不带专辑括号段', () {
      expect(
        buildSongShareText(testSongWithoutAlbum),
        '🎵 推荐歌曲：《稻香》 - 周杰伦\n来自 时音',
      );
    });

    test('专辑为空白字符串：同样视为无专辑，避免出现空括号段', () {
      const song = Song(
        id: '103',
        title: '七里香',
        artist: '周杰伦',
        hash: 'hash_qilixiang',
        albumName: '   ',
      );
      final text = buildSongShareText(song);
      expect(text, '🎵 推荐歌曲：《七里香》 - 周杰伦\n来自 时音');
      expect(text, isNot(contains('专辑：')));
    });

    test('artist 为空：不残留「 - 」分隔符', () {
      const song = Song(
        id: '104',
        title: '晴天',
        artist: '',
        hash: 'hash_qingtian_no_artist',
      );
      final text = buildSongShareText(song);
      expect(text, '🎵 推荐歌曲：《晴天》\n来自 时音');
      expect(text, isNot(contains(' - ')));
    });

    test('title 为空：用「未知歌曲」占位而不是空书名号', () {
      const song = Song(
        id: '105',
        title: '',
        artist: '周杰伦',
        hash: 'hash_unknown_title',
      );
      final text = buildSongShareText(song);
      expect(text, '🎵 推荐歌曲：《未知歌曲》 - 周杰伦\n来自 时音');
      expect(text, isNot(contains('《》')));
    });

    test('title 与 artist 均为空：文案仍完整可用，无残缺分隔符', () {
      const song = Song(
        id: '106',
        title: '',
        artist: '',
        hash: 'hash_empty_meta',
      );
      final text = buildSongShareText(song);
      expect(text, '🎵 推荐歌曲：《未知歌曲》\n来自 时音');
      expect(text, isNot(contains('《》')));
      expect(text, isNot(contains(' - ')));
      expect(text.endsWith('\n来自 时音'), isTrue);
    });

    test('品牌行固定为「来自 时音」，不残留上游 KA Music 品牌', () {
      for (final song in [testSong, testSongWithoutAlbum]) {
        final text = buildSongShareText(song);
        expect(text.endsWith('\n来自 时音'), isTrue);
        expect(text, isNot(contains('KA Music')));
      }
    });
  });

  group('copySongShareText', () {
    testWidgets('写入剪贴板并弹出统一 Toast 提示', (tester) async {
      final copiedText = installClipboardSpy(tester);

      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: Toast.navigatorKey,
          home: const Scaffold(body: SizedBox.shrink()),
        ),
      );

      await copySongShareText(testSong);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(copiedText(), buildSongShareText(testSong));
      expect(find.text('已复制歌曲分享信息到剪贴板'), findsOneWidget);

      // 走完 2 秒自动消失动画，避免测试结束时留下未触发的 Timer。
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(find.text('已复制歌曲分享信息到剪贴板'), findsNothing);
    });

    testWidgets('剪贴板写入失败：不抛未捕获异常、提示失败且不误报成功', (tester) async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          throw PlatformException(code: 'clipboard-unavailable');
        }
        return null;
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(SystemChannels.platform, null);
      });

      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: Toast.navigatorKey,
          home: const Scaffold(body: SizedBox.shrink()),
        ),
      );

      await copySongShareText(testSong);
      // 先让失败的平台通道调用落到 catch，再等错误 Toast 淡入。
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(tester.takeException(), isNull);
      expect(find.text('复制失败，请稍后重试'), findsOneWidget);
      // 失败时不能误报成功文案。
      expect(find.text('已复制歌曲分享信息到剪贴板'), findsNothing);

      // 错误 Toast 3 秒后自动消失：pump 完计时器与退场动画，
      // 避免测试结束时留下 pending timer。
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(find.text('复制失败，请稍后重试'), findsNothing);
    });
  });

  group('移动端底部弹窗', () {
    testWidgets('header 有分享入口，点击后复制统一文案并关闭弹窗', (tester) async {
      debugDesktopFormFactorOverride = false;
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());
      final copiedText = installClipboardSpy(tester);

      await tester.pumpWidget(
        buildSheetHost(size: const Size(400, 800)),
      );
      await tester.tap(find.text('Open Menu'));
      await tester.pumpAndSettle();

      expect(find.byType(BottomSheet), findsOneWidget);
      // 分享入口在 Song info 行右侧，且与车机/桌面共用同一 tooltip/图标。
      expect(find.byTooltip('分享歌曲'), findsOneWidget);
      expect(find.byIcon(Icons.share_outlined), findsOneWidget);

      await tester.tap(find.byTooltip('分享歌曲'));
      await tester.pump();
      await tester.pumpAndSettle();

      expect(copiedText(), buildSongShareText(testSong));
      expect(find.byType(BottomSheet), findsNothing);
    });

    testWidgets('弹窗内不再有「复制歌曲信息」类重复入口', (tester) async {
      debugDesktopFormFactorOverride = false;
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(
        buildSheetHost(size: const Size(400, 800)),
      );
      await tester.tap(find.text('Open Menu'));
      await tester.pumpAndSettle();

      expect(find.text('复制歌曲信息'), findsNothing);
      expect(find.text('分享歌曲'), findsNothing); // 入口是图标按钮，仅 tooltip 说明
    });
  });

  group('车机左侧滑入弹窗', () {
    testWidgets('header 有分享入口，点击后复制统一文案并关闭弹窗', (tester) async {
      debugDesktopFormFactorOverride = false;
      await ThemeController.instance.setCarModeEnabled(true);
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());
      final copiedText = installClipboardSpy(tester);

      await tester.pumpWidget(
        buildSheetHost(size: const Size(1280, 800)),
      );
      await tester.tap(find.text('Open Menu'));
      await tester.pumpAndSettle();

      expect(find.byType(GridView), findsOneWidget);
      expect(find.byTooltip('分享歌曲'), findsOneWidget);
      expect(find.byIcon(Icons.share_outlined), findsOneWidget);

      await tester.tap(find.byTooltip('分享歌曲'));
      await tester.pump();
      await tester.pumpAndSettle();

      expect(copiedText(), buildSongShareText(testSong));
      expect(find.byType(GridView), findsNothing);
    });
  });

  group('桌面歌曲操作菜单', () {
    testWidgets('锚定级联菜单 header 有分享入口，点击后复制并关闭菜单', (tester) async {
      debugDesktopFormFactorOverride = true;
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());
      final copiedText = installClipboardSpy(tester);

      await tester.pumpWidget(
        buildSheetHost(
          size: const Size(1280, 800),
          anchor: const Offset(400, 300),
        ),
      );
      await tester.tap(find.text('Open Menu'));
      await tester.pumpAndSettle();

      expect(find.byType(Dialog), findsNothing); // 有 anchor 时走级联菜单路由
      expect(find.byTooltip('分享歌曲'), findsOneWidget);

      final headerRow = find
          .ancestor(of: find.byType(Artwork), matching: find.byType(Row))
          .first;

      // 分享入口必须是 28×28 的紧凑点击区且不撑高 header 行：
      // 旧实现用 IconButton，Material3 compact density 下外层 _InputPadding
      // 仍按 48−8=40 布局，会把 header 行高从 32 撑到 40、菜单整体 +8px。
      final shareSize = tester.getSize(find.byTooltip('分享歌曲'));
      expect(shareSize, const Size(28, 28));
      // header 内 32px 封面不应被撑大（行高由它决定，保持 32 而非 40）。
      expect(tester.getSize(find.byType(Artwork)), const Size(32, 32));
      // header 行高实测保持 32：分享按钮不再把整行撑到 40（菜单 +8px）。
      expect(tester.getSize(headerRow).height, 32);

      await tester.tap(find.byTooltip('分享歌曲'));
      await tester.pump();
      await tester.pumpAndSettle();

      expect(copiedText(), buildSongShareText(testSong));
      expect(find.byTooltip('分享歌曲'), findsNothing);
    });

    testWidgets('居中兜底弹窗复用同一 header 分享入口', (tester) async {
      debugDesktopFormFactorOverride = true;
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());
      final copiedText = installClipboardSpy(tester);

      // 无 anchor（首个横屏帧等场景）时退回居中 Dialog，同样要有分享入口。
      await tester.pumpWidget(
        buildSheetHost(size: const Size(1280, 800)),
      );
      await tester.tap(find.text('Open Menu'));
      await tester.pumpAndSettle();

      expect(find.byType(Dialog), findsOneWidget);
      expect(find.byTooltip('分享歌曲'), findsOneWidget);

      await tester.tap(find.byTooltip('分享歌曲'));
      await tester.pump();
      await tester.pumpAndSettle();

      expect(copiedText(), buildSongShareText(testSong));
      expect(find.byType(Dialog), findsNothing);
    });
  });
}
