import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/ui/widgets/desktop_anchored_menu.dart';
import 'package:shiyin_music/ui/widgets/desktop_queue_panel.dart';

Finder _panelPositionedFinder() {
  return find.byWidgetPredicate(
    (w) =>
        w is Positioned &&
        w.width == kDesktopQueuePanelWidth &&
        w.height == kDesktopQueuePanelHeight,
  );
}

class _FakePlayerController extends ChangeNotifier
    implements PlayerController {
  @override
  Song? currentSong;
  @override
  List<Song> queue = const [];
  @override
  bool isPlaying = false;

  final List<Song> playCalls = [];
  final List<List<Song>?> playQueueArgs = [];

  @override
  Future<void> playSong(
    Song song, {
    List<Song>? queue,
    bool isRetry = false,
  }) async {
    playCalls.add(song);
    playQueueArgs.add(queue);
    currentSong = song;
    if (queue != null) this.queue = queue;
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Song _song(int n) => Song(
      id: '$n',
      title: '测试歌曲$n',
      artist: '测试歌手',
      hash: 'hash-$n',
      duration: const Duration(minutes: 3, seconds: 45),
    );

Future<_FakePlayerController> _pumpHarness(
  WidgetTester tester, {
  required _FakePlayerController player,
  Size windowSize = const Size(1280, 800),
}) async {
  tester.view.physicalSize = windowSize;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomRight,
          child: Padding(
            // 与窗口右缘留出距离，使面板可完整右对齐按钮（不触发右缘钳制）。
            padding: const EdgeInsets.only(right: 60),
            child: Builder(
              builder: (buttonContext) => IconButton(
                tooltip: '播放队列',
                onPressed: () => showDesktopQueuePanel(buttonContext, player),
                icon: const Icon(Icons.queue_music_rounded),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return player;
}

Future<void> _openPanel(WidgetTester tester) async {
  await tester.tap(find.byTooltip('播放队列'));
  await tester.pumpAndSettle();
}

void main() {
  group('placeAnchoredPanelAbove 纯函数', () {
    test('正常情况：面板底缘贴锚点上方、右对齐锚点', () {
      final rect = placeAnchoredPanelAbove(
        anchor: const Offset(900, 700),
        panelSize: const Size(360, 480),
        screenSize: const Size(1280, 800),
      );

      expect(rect.right, 900);
      expect(rect.bottom, 700);
      expect(rect.left, 900 - 360);
      expect(rect.top, 700 - 480);
    });

    test('右缘溢出：钳制到屏幕右边距内（≥12px）', () {
      final rect = placeAnchoredPanelAbove(
        anchor: const Offset(1276, 700),
        panelSize: const Size(360, 480),
        screenSize: const Size(1280, 800),
      );

      expect(rect.right, 1280 - 12);
      expect(rect.left, 1280 - 12 - 360);
    });

    test('锚点过近窗口顶部：底缘向下收进屏幕，保证顶边距', () {
      final rect = placeAnchoredPanelAbove(
        anchor: const Offset(600, 30),
        panelSize: const Size(360, 480),
        screenSize: const Size(1280, 800),
      );

      expect(rect.top, 12);
      expect(rect.bottom, 12 + 480);
    });

    test('窗口太小：面板收缩到可用区域并贴 12px 边距', () {
      // 宽高都放不下：宽 360→276、高 480→376，锚点双向越界被钳回边距处。
      final rect = placeAnchoredPanelAbove(
        anchor: const Offset(280, 380),
        panelSize: const Size(360, 480),
        screenSize: const Size(300, 400),
      );

      expect(rect.left, 12);
      expect(rect.top, 12);
      expect(rect.width, 300 - 24);
      expect(rect.height, 400 - 24);
    });

    test('最小窗口 960x600：面板完整可见且四周 ≥12px', () {
      // 底栏高 72，按钮顶边 ≈ 528，右缘留 12px。
      final rect = placeAnchoredPanelAbove(
        anchor: const Offset(948, 528),
        panelSize: const Size(360, 480),
        screenSize: const Size(960, 600),
      );

      expect(rect.left, greaterThanOrEqualTo(12));
      expect(rect.top, greaterThanOrEqualTo(12));
      expect(rect.right, lessThanOrEqualTo(960 - 12));
      expect(rect.bottom, lessThanOrEqualTo(600 - 12));
      expect(rect.width, 360);
      expect(rect.height, 480);
    });

    test('锚点在窗口外（负坐标）：结果仍钳制在边距内', () {
      final rect = placeAnchoredPanelAbove(
        anchor: const Offset(-40, -40),
        panelSize: const Size(360, 480),
        screenSize: const Size(1280, 800),
      );

      expect(rect.left, greaterThanOrEqualTo(12));
      expect(rect.top, greaterThanOrEqualTo(12));
      expect(rect.right, lessThanOrEqualTo(1280 - 12));
      expect(rect.bottom, lessThanOrEqualTo(800 - 12));
    });

    test('零尺寸窗口不崩溃', () {
      final rect = placeAnchoredPanelAbove(
        anchor: Offset.zero,
        panelSize: const Size(360, 480),
        screenSize: Size.zero,
      );

      expect(rect.width, 0);
      expect(rect.height, 0);
    });

    test('自定义边距生效', () {
      final rect = placeAnchoredPanelAbove(
        anchor: const Offset(600, 400),
        panelSize: const Size(360, 480),
        screenSize: const Size(1280, 800),
        margin: 24,
      );

      // 锚点太靠顶放不下完整面板：底缘被钳制到 顶边距+面板高，保证上边距。
      expect(rect.right, 600);
      expect(rect.top, 24);
      expect(rect.bottom, 24 + 480);
      expect(rect.left, greaterThanOrEqualTo(24));
      expect(rect.top, greaterThanOrEqualTo(24));
    });
  });

  group('showDesktopQueuePanel 路由', () {
    testWidgets('打开面板：标题计数、行内容、时长渲染，锚定在按钮上方', (tester) async {
      final player = _FakePlayerController()
        ..queue = [_song(1), _song(2), _song(3)]
        ..currentSong = _song(2)
        ..isPlaying = true;
      await _pumpHarness(tester, player: player);
      await _openPanel(tester);

      expect(find.text('播放队列'), findsOneWidget);
      expect(find.text('3 首'), findsOneWidget);
      expect(find.text('测试歌曲1'), findsOneWidget);
      expect(find.text('测试歌曲2'), findsOneWidget);
      expect(find.text('测试歌曲3'), findsOneWidget);
      expect(find.text('03:45'), findsNWidgets(3));

      // 锚定：面板右缘贴按钮右缘，底缘贴按钮顶边（出现在按钮上方、右对齐）。
      // 取按钮自身渲染盒（与 anchorAboveRight 解析的一致），而非内部 Tooltip 盒。
      final buttonTopRight =
          tester.getTopRight(find.byType(IconButton).first);
      final positioned =
          tester.widget<Positioned>(_panelPositionedFinder());
      expect(positioned.left! + positioned.width!, buttonTopRight.dx);
      expect(positioned.top! + positioned.height!, buttonTopRight.dy);

      // barrier：全屏半透明、可点击关闭。
      final barrier = tester.widget<ModalBarrier>(
        find.byType(ModalBarrier).last,
      );
      expect(barrier.dismissible, isTrue);
    });

    testWidgets('点击 barrier 关闭面板，不触发播放', (tester) async {
      final player = _FakePlayerController()
        ..queue = [_song(1), _song(2)]
        ..currentSong = _song(1)
        ..isPlaying = true;
      await _pumpHarness(tester, player: player);
      await _openPanel(tester);
      expect(_panelPositionedFinder(), findsOneWidget);

      await tester.tapAt(const Offset(300, 200));
      await tester.pumpAndSettle();

      expect(_panelPositionedFinder(), findsNothing);
      expect(player.playCalls, isEmpty);
    });

    testWidgets('按 Esc 关闭面板', (tester) async {
      final player = _FakePlayerController()
        ..queue = [_song(1), _song(2)]
        ..currentSong = _song(1)
        ..isPlaying = true;
      await _pumpHarness(tester, player: player);
      await _openPanel(tester);
      expect(_panelPositionedFinder(), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(_panelPositionedFinder(), findsNothing);
    });

    testWidgets('收起按钮关闭面板', (tester) async {
      final player = _FakePlayerController()
        ..queue = [_song(1), _song(2)]
        ..currentSong = _song(1);
      await _pumpHarness(tester, player: player);
      await _openPanel(tester);

      await tester.tap(find.byTooltip('收起'));
      await tester.pumpAndSettle();

      expect(_panelPositionedFinder(), findsNothing);
      expect(player.playCalls, isEmpty);
    });

    testWidgets('点击行切到该首（与 queue_sheet 同语义）并关闭面板', (tester) async {
      final songs = [_song(1), _song(2), _song(3)];
      final player = _FakePlayerController()
        ..queue = songs
        ..currentSong = songs[0]
        ..isPlaying = true;
      await _pumpHarness(tester, player: player);
      await _openPanel(tester);

      await tester.tap(find.text('测试歌曲3'));
      await tester.pumpAndSettle();

      expect(player.playCalls, [songs[2]]);
      expect(player.playQueueArgs.single, songs);
      expect(_panelPositionedFinder(), findsNothing);
    });

    testWidgets('当前播放行高亮：正在播放指示替换序号、主题色底', (tester) async {
      final songs = [_song(1), _song(2), _song(3)];
      final player = _FakePlayerController()
        ..queue = songs
        ..currentSong = songs[1]
        ..isPlaying = true;
      await _pumpHarness(tester, player: player);
      await _openPanel(tester);

      // 正在播放行：序号被指示图标替换，且面板内唯一。
      expect(find.byIcon(Icons.equalizer_rounded), findsOneWidget);
      expect(find.text('2'), findsNothing);
      // 非当前行仍显示序号。
      expect(find.text('1'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);

      // 当前行底色 = primary 9% 高亮。
      final container = tester.widget<AnimatedContainer>(
        find.ancestor(
          of: find.text('测试歌曲2'),
          matching: find.byType(AnimatedContainer),
        ),
      );
      final decoration = container.decoration! as BoxDecoration;
      expect(
        decoration.color,
        Theme.of(tester.element(find.text('测试歌曲2')))
            .colorScheme
            .primary
            .withValues(alpha: .09),
      );

      // 暂停状态：指示图标切换为暂停。
      player.isPlaying = false;
      player.notifyListeners();
      await tester.pump();
      expect(find.byIcon(Icons.pause_rounded), findsOneWidget);
      expect(find.byIcon(Icons.equalizer_rounded), findsNothing);
    });

    testWidgets('长队列打开时自动滚动到正在播放行', (tester) async {
      final songs = List<Song>.generate(30, (i) => _song(i + 1));
      final player = _FakePlayerController()
        ..queue = songs
        ..currentSong = songs[19] // 第 20 首
        ..isPlaying = true;
      await _pumpHarness(tester, player: player);
      await _openPanel(tester);

      // 第 20 行在可视区中，第 1 行已被滚出（懒加载不构建）。
      expect(find.text('测试歌曲20'), findsOneWidget);
      expect(find.text('测试歌曲1'), findsNothing);
    });

    testWidgets('最小窗口 960x600：面板完整落在窗口内（四周 ≥12px）', (tester) async {
      final player = _FakePlayerController()
        ..queue = [_song(1), _song(2)]
        ..currentSong = _song(1)
        ..isPlaying = true;
      await _pumpHarness(
        tester,
        player: player,
        windowSize: const Size(960, 600),
      );
      await _openPanel(tester);

      final positioned = tester.widget<Positioned>(_panelPositionedFinder());
      final left = positioned.left!;
      final top = positioned.top!;
      expect(left, greaterThanOrEqualTo(12));
      expect(top, greaterThanOrEqualTo(12));
      expect(left + positioned.width!, lessThanOrEqualTo(960 - 12));
      expect(top + positioned.height!, lessThanOrEqualTo(600 - 12));
    });

    testWidgets('空队列：显示空态文案', (tester) async {
      final player = _FakePlayerController()..currentSong = _song(1);
      await _pumpHarness(tester, player: player);
      await _openPanel(tester);

      expect(find.text('播放队列为空'), findsOneWidget);
      expect(find.text('0 首'), findsOneWidget);
    });
  });
}
