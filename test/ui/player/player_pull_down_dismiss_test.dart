import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyin_music/controllers/auth_controller.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/controllers/theme_controller.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/services/music_api.dart';
import 'package:shiyin_music/ui/form_factor.dart';
import 'package:shiyin_music/ui/pages/player_page.dart';
import 'package:shiyin_music/ui/player/player_top_bar.dart';
import 'package:shiyin_music/ui/widgets/artwork.dart';

class _FakeApi implements MusicApi {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakePlayerController extends ChangeNotifier
    implements PlayerController {
  @override
  Song? currentSong = const Song(
    id: 'test-song-1',
    title: '晴天',
    artist: '周杰伦',
    hash: 'hash-test-1',
    source: SongSource.kugou,
    coverUrl: 'https://example.com/cover.jpg',
  );

  @override
  List<Song> queue = const [
    Song(
      id: 'test-song-1',
      title: '晴天',
      artist: '周杰伦',
      hash: 'hash-test-1',
      source: SongSource.kugou,
      coverUrl: 'https://example.com/cover.jpg',
    ),
  ];

  @override
  Duration duration = const Duration(minutes: 4, seconds: 29);

  @override
  final ValueNotifier<Duration> positionListenable =
      ValueNotifier<Duration>(Duration.zero);

  @override
  Duration position = const Duration(seconds: 30);

  @override
  Duration get smoothPosition => position;

  @override
  bool isPlaying = false;

  @override
  bool isPreparing = false;

  @override
  bool isScrubbing = false;

  @override
  PlaybackMode playbackMode = PlaybackMode.playlistLoop;

  @override
  String get playbackModeLabel => '列表循环';

  @override
  AudioQuality audioQuality = AudioQuality.standard;

  @override
  String playbackSpeedLabel = '1.0x';

  @override
  bool isAudioEffectsSupported = true;

  @override
  String get audioEffectsLabel => '音效已开启';

  @override
  bool isDesktopLyricsSupported = false;

  @override
  bool desktopLyricsEnabled = false;

  @override
  List<LyricLine> lyrics = const [
    LyricLine(time: Duration.zero, text: '故事的小黄花'),
  ];

  @override
  int get activeLyricIndex => 0;

  @override
  Future<void> ensureLyricsLoaded() async {}

  @override
  Future<void> seekToAndPlay(Duration position) async {}

  @override
  SongClimax? climax;

  @override
  MusicApi get api => _FakeApi();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeAuthController extends ChangeNotifier implements AuthController {
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

  Widget buildTestApp({
    required PlayerController player,
    required AuthController auth,
    Size size = const Size(390, 844),
  }) {
    return MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(size: size),
        child: SizedBox(
          width: size.width,
          height: size.height,
          child: PlayerPage(
            player: player,
            auth: auth,
          ),
        ),
      ),
    );
  }

  group('PlayerPage 顶层下拉手势与动态圆角测试', () {
    testWidgets('初始状态具有 player_body_dismiss_transform 且平移为0、顶部圆角为0', (tester) async {
      final player = _FakePlayerController();
      final auth = _FakeAuthController();

      await tester.pumpWidget(buildTestApp(player: player, auth: auth));
      await tester.pump(const Duration(milliseconds: 100));

      final transformFinder = find.byKey(const Key('player_body_dismiss_transform'));
      expect(transformFinder, findsOneWidget);

      final Transform transform = tester.widget(transformFinder);
      expect(transform.transform.getTranslation().y, equals(0.0));

      final clipFinder = find.byKey(const Key('player_body_dismiss_clip'));
      expect(clipFinder, findsOneWidget);
      final ClipRRect clip = tester.widget(clipFinder);
      final borderRadius = clip.borderRadius as BorderRadius;
      expect(borderRadius.topLeft, equals(Radius.zero));
      expect(borderRadius.topRight, equals(Radius.zero));
    });

    testWidgets('在 PosterPlayerPage 区域向下拉动 50px：整个页面平移 50px 且带出 12px 顶部圆角', (tester) async {
      final player = _FakePlayerController();
      final auth = _FakeAuthController();

      await tester.pumpWidget(buildTestApp(player: player, auth: auth));
      await tester.pump(const Duration(milliseconds: 100));

      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(Artwork).first),
      );
      await gesture.moveBy(const Offset(0, 50));
      await tester.pump();

      final transformFinder = find.byKey(const Key('player_body_dismiss_transform'));
      final Transform transform = tester.widget(transformFinder);
      expect(transform.transform.getTranslation().y, closeTo(50.0, 1.0));

      final clipFinder = find.byKey(const Key('player_body_dismiss_clip'));
      final ClipRRect clip = tester.widget(clipFinder);
      final borderRadius = clip.borderRadius as BorderRadius;
      expect(borderRadius.topLeft, equals(const Radius.circular(12.0)));
      expect(borderRadius.topRight, equals(const Radius.circular(12.0)));

      await gesture.up();
      await tester.pump(const Duration(milliseconds: 300));
    });

    testWidgets('向下拉动未达阈值 (< 80px) 松手回弹至 0，顶部圆角重置为 0', (tester) async {
      final player = _FakePlayerController();
      final auth = _FakeAuthController();

      await tester.pumpWidget(buildTestApp(player: player, auth: auth));
      await tester.pump(const Duration(milliseconds: 100));

      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(Artwork).first),
      );
      await gesture.moveBy(const Offset(0, 40));
      await tester.pump();

      final transformFinder = find.byKey(const Key('player_body_dismiss_transform'));
      Transform transform = tester.widget(transformFinder);
      expect(transform.transform.getTranslation().y, closeTo(40.0, 1.0));

      await gesture.up();
      await tester.pump();

      // 回弹动画 250ms
      await tester.pump(const Duration(milliseconds: 300));

      transform = tester.widget(transformFinder);
      expect(transform.transform.getTranslation().y, equals(0.0));

      final clipFinder = find.byKey(const Key('player_body_dismiss_clip'));
      final ClipRRect clip = tester.widget(clipFinder);
      final borderRadius = clip.borderRadius as BorderRadius;
      expect(borderRadius.topLeft, equals(Radius.zero));
      expect(borderRadius.topRight, equals(Radius.zero));
    });

    testWidgets('在 TopBar 区域向下拉动 50px：同样驱动整页平移与动态圆角', (tester) async {
      final player = _FakePlayerController();
      final auth = _FakeAuthController();

      await tester.pumpWidget(buildTestApp(player: player, auth: auth));
      await tester.pump(const Duration(milliseconds: 100));

      final topBarFinder = find.byType(TopBar);
      expect(topBarFinder, findsOneWidget);

      final gesture = await tester.startGesture(tester.getCenter(topBarFinder));
      await gesture.moveBy(const Offset(0, 50));
      await tester.pump();

      final transformFinder = find.byKey(const Key('player_body_dismiss_transform'));
      final Transform transform = tester.widget(transformFinder);
      expect(transform.transform.getTranslation().y, closeTo(50.0, 1.0));

      final clipFinder = find.byKey(const Key('player_body_dismiss_clip'));
      final ClipRRect clip = tester.widget(clipFinder);
      final borderRadius = clip.borderRadius as BorderRadius;
      expect(borderRadius.topLeft, equals(const Radius.circular(12.0)));
      expect(borderRadius.topRight, equals(const Radius.circular(12.0)));

      await gesture.up();
      await tester.pump(const Duration(milliseconds: 300));
    });

    testWidgets('向下拉动超过 80px 释放：动画平滑滑出屏幕底部并退出播放页', (tester) async {
      final player = _FakePlayerController();
      final auth = _FakeAuthController();

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => PlayerPage(player: player, auth: auth),
                ),
              ),
              child: const Text('Open Player'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open Player'));
      for (var i = 0; i < 15; i++) {
        await tester.pump(const Duration(milliseconds: 25));
      }
      expect(find.byType(PlayerPage), findsOneWidget);

      // 下拉 100px 并松手
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(Artwork).first),
      );
      await gesture.moveBy(const Offset(0, 100));
      await tester.pump();

      await gesture.up();
      await tester.pump();

      // 在滑出过程中，页面下移行进中
      await tester.pump(const Duration(milliseconds: 100));
      final transformFinder = find.byKey(const Key('player_body_dismiss_transform'));
      final Transform transform = tester.widget(transformFinder);
      expect(transform.transform.getTranslation().y, greaterThan(100.0));

      // 动画完成 (200ms) 并触发 pop，pop 动画完成
      for (var i = 0; i < 35; i++) {
        await tester.pump(const Duration(milliseconds: 25));
      }

      // 播放页已完全 pop
      expect(find.byType(PlayerPage), findsNothing);
    });

    testWidgets('快速向下甩动 (velocity > 800px/s) 释放：平滑滑出屏幕底部并退出播放页', (tester) async {
      final player = _FakePlayerController();
      final auth = _FakeAuthController();

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => PlayerPage(player: player, auth: auth),
                ),
              ),
              child: const Text('Open Player'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open Player'));
      for (var i = 0; i < 15; i++) {
        await tester.pump(const Duration(milliseconds: 25));
      }
      expect(find.byType(PlayerPage), findsOneWidget);

      await tester.fling(
        find.byType(Artwork).first,
        const Offset(0, 60),
        1000,
      );
      await tester.pump();

      // 推进退场动画 (200ms dismiss + 300ms route pop)
      for (var i = 0; i < 35; i++) {
        await tester.pump(const Duration(milliseconds: 25));
      }

      // 播放页已 pop
      expect(find.byType(PlayerPage), findsNothing);
    });

    testWidgets('在歌词页面内垂直滑动仅用于歌词滚动，不触发播放页整页下拉平移', (tester) async {
      final player = _FakePlayerController();
      final auth = _FakeAuthController();

      await tester.pumpWidget(buildTestApp(player: player, auth: auth));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 25));
      }

      // 水平向左滑动手势切换到歌词页 (第 1 页)
      await tester.drag(find.byKey(const PageStorageKey('poster-player-page')), const Offset(-400, 0));
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 25));
      }

      // 验证歌词页已处于活动状态
      final lyricPageFinder = find.byKey(const PageStorageKey('lyric-player-page'));
      expect(lyricPageFinder, findsOneWidget);

      // 在歌词列表区域垂直向下拉动 100px
      final gesture = await tester.startGesture(tester.getCenter(lyricPageFinder));
      await gesture.moveBy(const Offset(0, 100));
      await tester.pump();

      // 整页 Transform.translate 的 y 位移必须保持为 0，不被下拉触发
      final transformFinder = find.byKey(const Key('player_body_dismiss_transform'));
      final Transform transform = tester.widget(transformFinder);
      expect(transform.transform.getTranslation().y, equals(0.0));

      // 顶部圆角也保持为 0
      final clipFinder = find.byKey(const Key('player_body_dismiss_clip'));
      final ClipRRect clip = tester.widget(clipFinder);
      final borderRadius = clip.borderRadius as BorderRadius;
      expect(borderRadius.topLeft, equals(Radius.zero));
      expect(borderRadius.topRight, equals(Radius.zero));

      await gesture.up();
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 25));
      }
      expect(find.byType(PlayerPage), findsOneWidget);
    });
  });
}
