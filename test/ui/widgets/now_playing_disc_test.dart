// - 视觉：58 盘体 / 46 外环 / 38 旋转封面，无文字；
// - 性能：明确不允许 BackdropFilter（车机/低端机零离屏合成红线）；
// - 动画：仅「播放中 + 前台」旋转，暂停立即停；进度环只随 positionListenable 更新；
// - 首页底栏 CenterDisc 复用同一实现（旋转封面 + 环形进度）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/controllers/auth_controller.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/ui/pages/app_shell.dart';
import 'package:shiyin_music/ui/widgets/artwork.dart';
import 'package:shiyin_music/ui/widgets/marquee_text.dart';
import 'package:shiyin_music/ui/widgets/mini_player.dart';
import 'package:shiyin_music/ui/widgets/now_playing_disc.dart';

class _FakePlayerController extends ChangeNotifier implements PlayerController {
  @override
  bool isPersonalFmActive = false;

  @override
  bool isLoadingPersonalFm = false;

  @override
  Future<bool> startPersonalFm({List<Song>? initialSongs}) async => false;

  @override
  Song? currentSong;

  @override
  List<Song> queue = [];

  @override
  bool isPlaying = true;

  @override
  bool isPreparing = false;

  @override
  Duration position = const Duration(seconds: 60);

  @override
  Duration duration = const Duration(seconds: 120);

  @override
  String? errorMessage;

  @override
  final ValueNotifier<Duration> positionListenable =
      ValueNotifier(const Duration(seconds: 60));

  @override
  Future<void> togglePlay() async {
    isPlaying = !isPlaying;
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeAuthController extends ChangeNotifier implements AuthController {
  @override
  bool isLiked(Song song) => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _song = Song(
  id: 'song_1',
  title: '测试歌曲',
  artist: '测试歌手',
  hash: 'hash_1',
);

Widget _wrap(Widget child) => MaterialApp(
      home: Scaffold(
        body: Align(alignment: Alignment.bottomCenter, child: child),
      ),
    );

double _turns(WidgetTester tester) => tester
    .widget<RotationTransition>(find.byType(RotationTransition).first)
    .turns
    .value;

void main() {
  testWidgets('悬浮唱片：58/46/38 几何、无文字、无 BackdropFilter，进度环随进度刷新',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final player = _FakePlayerController()..currentSong = _song;
    await tester.pumpWidget(
      _wrap(MiniPlayer(player: player, auth: _FakeAuthController())),
    );
    await tester.pump();

    expect(tester.getSize(find.byType(NowPlayingDisc)), const Size(46, 46));
    expect(tester.getSize(find.byType(MiniPlayer)).height, 58);
    final artwork = tester.widget<Artwork>(find.byType(Artwork).first);
    expect(artwork.size, 38);

    // 性能红线：圆盘不允许 backdrop blur（车机/低端机离屏合成）。
    expect(find.byType(BackdropFilter), findsNothing);
    // 纯圆盘形态：不再有歌名/歌手文字。
    expect(find.byType(MarqueeText), findsNothing);
    expect(find.text('测试歌手'), findsNothing);

    // 进度环值 = position / duration（60/120 → 0.5）。
    final ring = tester.widget<CircularProgressIndicator>(
      find.byType(CircularProgressIndicator).first,
    );
    expect(ring.value, closeTo(0.5, .01));
  });

  testWidgets('播放中旋转、暂停立即停：不空转 ticker', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final player = _FakePlayerController()..currentSong = _song;
    await tester.pumpWidget(
      _wrap(MiniPlayer(player: player, auth: _FakeAuthController())),
    );
    await tester.pump();

    final t0 = _turns(tester);
    await tester.pump(const Duration(seconds: 2));
    expect(_turns(tester), greaterThan(t0));

    player.isPlaying = false;
    player.notifyListeners();
    await tester.pump();
    final pausedAt = _turns(tester);
    await tester.pump(const Duration(seconds: 2));
    expect(_turns(tester), pausedAt);

    // 恢复播放后继续转。
    player.isPlaying = true;
    player.notifyListeners();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(_turns(tester), greaterThan(pausedAt));
  });

  testWidgets('播放错误时进度环转错误色（圆盘唯一的无文字错误反馈）', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final player = _FakePlayerController()
      ..currentSong = _song
      ..errorMessage = '该歌曲需要 VIP 才能播放';
    await tester.pumpWidget(
      _wrap(MiniPlayer(player: player, auth: _FakeAuthController())),
    );
    await tester.pump();

    final context = tester.element(find.byType(MiniPlayer));
    final errorColor = Theme.of(context).colorScheme.error;
    final ring = tester.widget<CircularProgressIndicator>(
      find.byType(CircularProgressIndicator).first,
    );
    expect(
      (ring.valueColor as AlwaysStoppedAnimation<Color>).value,
      errorColor,
    );
  });

  testWidgets('窄屏 320dp 不溢出', (tester) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final player = _FakePlayerController()..currentSong = _song;
    await tester.pumpWidget(
      _wrap(MiniPlayer(player: player, auth: _FakeAuthController())),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('首页底栏 CenterDisc 复用同一旋转唱片实现', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final player = _FakePlayerController()..currentSong = _song;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: CenterDisc(player: player, auth: _FakeAuthController()),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(NowPlayingDisc), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(NowPlayingDisc),
        matching: find.byType(RotationTransition),
      ),
      findsOneWidget,
    );
    final t0 = _turns(tester);
    await tester.pump(const Duration(seconds: 2));
    expect(_turns(tester), greaterThan(t0));
  });
}
