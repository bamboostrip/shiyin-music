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

  testWidgets('按占比取宽：任何宽度都是 30% 屏宽（相当于 flex 3:7）', (tester) async {
    await pumpPanelAt(tester, const Size(1920, 1080));
    final at1920 = tester.getSize(find.byType(CarLeftPlayerPanel)).width;
    expect(at1920, closeTo(576, 0.5));
    expect(at1920 / 1920, closeTo(0.30, 0.01));

    // 不设上限：2560 逻辑宽（dpr=1 的 1440p 屏）也是 30%，不再是 25%。
    await pumpPanelAt(tester, const Size(2560, 1440));
    final at2560 = tester.getSize(find.byType(CarLeftPlayerPanel)).width;
    expect(at2560, closeTo(768, 0.5));
    expect(at2560 / 2560, closeTo(0.30, 0.01));
    expect(at2560, greaterThan(at1920), reason: '屏越宽面板越宽');
  });

  testWidgets('1280 逻辑宽维持旧观感：384 ≈ 旧 380（29.7% → 30%）', (tester) async {
    // 1920×1080 车机多数是 dpr 1.5 → 1280 逻辑宽，旧实现固定 380 = 29.7%，
    // 正好是 QQ 车机版的 ~29%——所以这类设备改完只差 4dp。
    await pumpPanelAt(tester, const Size(1280, 720));
    expect(tester.getSize(find.byType(CarLeftPlayerPanel)).width, closeTo(384, 0.5));

    // 1707（2560×1440 @dpr1.5）按 30% 取 512，比旧的 380 明显变宽——这正是
    // issue #24 用户要的。
    await pumpPanelAt(tester, const Size(1707, 960));
    expect(tester.getSize(find.byType(CarLeftPlayerPanel)).width, closeTo(512, 0.5));
  });

  testWidgets('1920×1080 回归：左栏不许超过 1/3 屏，封面不顶满面板', (tester) async {
    // v3.0.20 首版 33% + 「封面上限 = 面板内宽全额」，在 1920 上变成 634 的
    // 宽栏 + 两侧各 70dp 留白。这里同时钉住占比与封面留白。
    await pumpPanelAt(tester, const Size(1920, 1080));
    final panel = tester.getSize(find.byType(CarLeftPlayerPanel)).width;
    expect(panel / 1920, lessThan(0.32));
    expect(tester.getSize(find.byType(Artwork)).width, lessThan(panel * 0.80));
  });

  testWidgets('没有上限：4K 逻辑宽也是 30%，内部等比系数跟得上', (tester) async {
    await pumpPanelAt(tester, const Size(3840, 2160));
    final panel = tester.getSize(find.byType(CarLeftPlayerPanel)).width;
    expect(panel, closeTo(1152, 0.5));
    expect(panel / 3840, closeTo(0.30, 0.01));
    // 封面仍留白、不顶满（scale 上限 2.2 时 padding 会一起放大）
    expect(tester.getSize(find.byType(Artwork)).width, lessThan(panel * 0.82));
    expect(tester.takeException(), isNull);
  });

  testWidgets('小屏 320 下限：800×480 / 1024×600', (tester) async {
    await pumpPanelAt(tester, const Size(800, 480));
    expect(
      tester.getSize(find.byType(CarLeftPlayerPanel)).width,
      closeTo(320, 0.5),
    );

    await pumpPanelAt(tester, const Size(1024, 600));
    expect(
      tester.getSize(find.byType(CarLeftPlayerPanel)).width,
      closeTo(380, 0.5),
    );
  });

  testWidgets('小屏 800×480 缩小档不溢出', (tester) async {
    await pumpPanelAt(tester, const Size(800, 480));
    expect(tester.takeException(), isNull);
  });

  testWidgets('封面随屏幕一起放大，且不超过面板内容宽度', (tester) async {
    await pumpPanelAt(tester, const Size(1280, 720));
    final art1280 = tester.getSize(find.byType(Artwork)).width;

    await pumpPanelAt(tester, const Size(1707, 960));
    final art1707 = tester.getSize(find.byType(Artwork)).width;
    final panel1707 = tester.getSize(find.byType(CarLeftPlayerPanel)).width;

    expect(art1280, greaterThan(270), reason: '1280 封面应与旧值 280 同档');
    expect(art1707, greaterThan(art1280 * 1.25), reason: '高分车机封面要明显更大');
    expect(art1707, lessThan(panel1707 * 0.82), reason: '封面不能顶满面板');
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
    expect(tester.getSize(find.byType(Artwork)).width, greaterThan(270));
  });

  testWidgets('控件随面板等比放大（收藏/播放键不再有绝对上限）', (tester) async {
    await pumpPanelAt(tester, const Size(1280, 720));
    expect(
      tester.getSize(find.byIcon(Icons.favorite_border_rounded)).width,
      closeTo(34, 0.5),
    );
    expect(tester.getSize(find.byIcon(Icons.pause_rounded)).width, closeTo(40, 0.5));

    // scale 2.0：爱心 68、播放图标 80，而不是被旧的 44/76 天花板卡住。
    await pumpPanelAt(tester, const Size(2560, 1440));
    expect(
      tester.getSize(find.byIcon(Icons.favorite_border_rounded)).width,
      closeTo(68, 0.5),
    );
    expect(tester.getSize(find.byIcon(Icons.pause_rounded)).width, closeTo(80, 0.5));
  });

  testWidgets('原生 2560×1440（dpr=1）+ 系统大字号不溢出', (tester) async {
    // issue #24 用户的设备可能就是原生 2560×1440（dpr=1）：面板 768、
    // 封面 576、scale 2.0，是这次改动里面板最大的一档，必须钉住不溢出。
    await pumpPanelAt(tester, const Size(2560, 1440));
    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byType(Artwork)).width, greaterThan(500));

    for (final scaler in const [
      TextScaler.linear(1.12),
      TextScaler.linear(1.3),
    ]) {
      await pumpPanelAt(tester, const Size(2560, 1440), textScaler: scaler);
      expect(tester.takeException(), isNull, reason: 'textScaler $scaler 溢出');
    }
  });
}
