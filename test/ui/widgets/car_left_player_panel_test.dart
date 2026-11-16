import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyin_music/controllers/auth_controller.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/controllers/theme_controller.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/ui/form_factor.dart';
import 'package:shiyin_music/ui/widgets/artwork.dart';
import 'package:shiyin_music/ui/widgets/car_left_player_panel.dart';

const _song = Song(
  id: 'car-panel-song',
  title: '晴天',
  artist: '周杰伦',
  hash: 'hash-car-panel',
  source: SongSource.kugou,
  // 不给封面 URL：Artwork 走占位分支，测试不触网。
);

class _FakePlayer extends ChangeNotifier implements PlayerController {
  @override
  Song? currentSong = _song;

  @override
  List<Song> queue = const [_song];

  @override
  bool isPreparing = false;

  @override
  bool isPlaying = true;

  @override
  PlaybackMode playbackMode = PlaybackMode.playlistLoop;

  @override
  Duration duration = const Duration(minutes: 4, seconds: 29);

  @override
  Duration position = const Duration(seconds: 30);

  @override
  Duration get smoothPosition => position;

  @override
  final ValueNotifier<Duration> positionListenable = ValueNotifier<Duration>(
    Duration.zero,
  );

  @override
  Future<void> togglePlay() async {}

  @override
  Future<void> previous() async {}

  @override
  Future<void> next() async {}

  @override
  PlaybackMode cyclePlaybackMode() => playbackMode;

  @override
  void previewSeek(Duration position) {}

  @override
  Future<void> seek(Duration position) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeAuth extends ChangeNotifier implements AuthController {
  @override
  bool isLiked(Song song) => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ThemeController();
    debugDesktopFormFactorOverride = false;
  });

  tearDown(() {
    debugDesktopFormFactorOverride = null;
  });

  /// 按逻辑尺寸布局（dpr=1 时 physicalSize 即逻辑像素）。
  Future<void> pumpPanelAt(
    WidgetTester tester,
    Size logical, {
    TextScaler textScaler = TextScaler.noScaling,
  }) async {
    tester.view.physicalSize = logical;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final player = _FakePlayer();
    final auth = _FakeAuth();
    addTearDown(player.dispose);
    addTearDown(auth.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(size: logical, textScaler: textScaler),
          child: Scaffold(
            body: Row(
              children: [
                CarLeftPlayerPanel(player: player, auth: auth),
                const Expanded(child: SizedBox.expand()),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('面板宽度按窗口宽度比例（约 1/3），不再是固定 380', (tester) async {
    await pumpPanelAt(tester, const Size(1280, 720));
    final at1280 = tester.getSize(find.byType(CarLeftPlayerPanel)).width;
    expect(at1280, closeTo(1280 * 0.33, 0.5));

    await pumpPanelAt(tester, const Size(1707, 960));
    final at1707 = tester.getSize(find.byType(CarLeftPlayerPanel)).width;
    expect(at1707, closeTo(1707 * 0.33, 0.5));
    expect(at1707, greaterThan(at1280), reason: '高分车机上面板应同比变宽');

    // 2560×1600 车机（issue #24 用户设备）：逻辑宽 1707 时占比 33%，
    // 旧实现只有 22%。
    expect(at1707 / 1707, greaterThan(0.31));
  });

  testWidgets('小屏车机不劣化：320 下限与超宽屏 780 上限', (tester) async {
    await pumpPanelAt(tester, const Size(800, 480));
    expect(
      tester.getSize(find.byType(CarLeftPlayerPanel)).width,
      closeTo(320, 0.5),
    );

    await pumpPanelAt(tester, const Size(2560, 1440));
    expect(
      tester.getSize(find.byType(CarLeftPlayerPanel)).width,
      closeTo(780, 0.5),
    );
  });

  testWidgets('封面随屏幕一起放大，且不超过面板内容宽度', (tester) async {
    await pumpPanelAt(tester, const Size(1280, 720));
    final art1280 = tester.getSize(find.byType(Artwork)).width;

    await pumpPanelAt(tester, const Size(1707, 960));
    final art1707 = tester.getSize(find.byType(Artwork)).width;

    expect(art1280, greaterThan(200), reason: '1280 基线封面应不小于旧值 280 一级');
    expect(art1707, greaterThan(art1280 * 1.15), reason: '高分车机封面要明显更大');

    final panel1707 = tester.getSize(find.byType(CarLeftPlayerPanel)).width;
    expect(art1707, lessThan(panel1707), reason: '封面不能超出面板');
  });

  testWidgets('矮横屏（1280×480）不溢出', (tester) async {
    await pumpPanelAt(tester, const Size(1280, 480));
    expect(tester.takeException(), isNull);
  });

  testWidgets('高分屏叠加系统大字号（1707×960 × textScaler 1.3）不溢出', (tester) async {
    // 车机分支本身还会乘 1.12，用户又可能在系统里调大字号：封面放大后
    // 竖向余量变薄，这里把最容易溢出的一档钉住。
    await pumpPanelAt(
      tester,
      const Size(1707, 960),
      textScaler: const TextScaler.linear(1.3),
    );
    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byType(Artwork)).width, greaterThan(300));
  });
}
