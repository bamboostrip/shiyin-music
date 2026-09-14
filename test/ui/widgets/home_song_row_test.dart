import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/controllers/auth_controller.dart';
import 'package:shiyin_music/controllers/download_controller.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/ui/form_factor.dart';
import 'package:shiyin_music/ui/widgets/home_song_row.dart';
import 'package:shiyin_music/ui/widgets/now_playing_badge.dart';

class _FakePlayerController extends ChangeNotifier implements PlayerController {
  @override
  Song? currentSong;

  @override
  bool isPlaying = false;

  int togglePlayCount = 0;

  @override
  Future<void> togglePlay() async {
    togglePlayCount++;
    isPlaying = !isPlaying;
    notifyListeners();
  }

  // 右键菜单构建条目时读取（null = 无下载入口）。
  @override
  DownloadController? get downloadController => null;

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
  id: '1',
  title: '海阔天空',
  artist: 'Beyond',
  albumName: '乐与怒',
  duration: Duration(seconds: 325),
  hash: 'hash_home_row',
);

void main() {
  tearDown(() {
    debugDesktopFormFactorOverride = null;
  });

  Widget wrap(Widget child) {
    return MaterialApp(
      home: Scaffold(body: SizedBox(width: 800, child: child)),
    );
  }

  Widget buildRow({
    required void Function(Song song, List<Song> queue) onPlay,
    PlayerController? player,
  }) {
    return HomeSongRow(
      song: _song,
      queue: [_song],
      onPlay: onPlay,
      isLiked: false,
      onLikeTap: () {},
      auth: _FakeAuthController(),
      player: player ?? _FakePlayerController(),
      onViewArtist: () {},
    );
  }

  group('首页歌曲行 桌面端 (isDesktopFormFactor == true)', () {
    setUp(() {
      debugDesktopFormFactorOverride = true;
    });

    testWidgets('单击不触发播放', (tester) async {
      var played = 0;
      await tester.pumpWidget(wrap(buildRow(onPlay: (_, _) => played++)));

      await tester.tap(find.text('海阔天空'));
      // 等待双击超时，确认单击不会延迟触发播放
      await tester.pump(const Duration(milliseconds: 400));

      expect(played, 0);
    });

    testWidgets('双击触发播放并带上队列', (tester) async {
      final playedSongs = <Song>[];
      final playedQueues = <List<Song>>[];
      await tester.pumpWidget(
        wrap(
          buildRow(
            onPlay: (song, queue) {
              playedSongs.add(song);
              playedQueues.add(queue);
            },
          ),
        ),
      );

      await tester.tap(find.text('海阔天空'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('海阔天空'));
      await tester.pump(const Duration(milliseconds: 400));

      expect(playedSongs, [_song]);
      expect(playedQueues, [
        [_song],
      ]);
    });

    testWidgets('桌面端悬停封面浮现播放按钮，单击播放按钮单次即可播放', (tester) async {
      final playedSongs = <Song>[];
      await tester.pumpWidget(
        wrap(
          buildRow(
            onPlay: (song, queue) {
              playedSongs.add(song);
            },
          ),
        ),
      );

      // 未悬停时播放按钮不可见且不可命中（常驻树 + 透明度 0 实现浮现动画）
      expect(find.byIcon(Icons.play_arrow_rounded).hitTestable(), findsNothing);

      // 模拟鼠标悬停到整行
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      await gesture.moveTo(tester.getCenter(find.byType(HomeSongRow)));
      await tester.pumpAndSettle();

      // 悬停后封面浮现播放图标
      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);

      // 单击封面播放按钮（无需双击，单击即播）
      await tester.tap(find.byIcon(Icons.play_arrow_rounded));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      expect(playedSongs, [_song]);
      await gesture.removePointer();
    });

    testWidgets('右键弹出锚定上下文菜单（下一首播放/添加到歌单/查看歌手）',
        (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(wrap(buildRow(onPlay: (_, _) {})));

      // 行内右键（次级按钮按下）。
      final center = tester.getCenter(find.text('海阔天空'));
      final gesture = await tester.startGesture(
        center,
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryButton,
      );
      await gesture.up();
      await gesture.removePointer();
      await tester.pumpAndSettle();

      // 与 `...` 按钮同一份桌面菜单内容，锚定在点击处弹出。
      expect(find.text('下一首播放'), findsOneWidget);
      expect(find.text('添加到歌单'), findsOneWidget);
      expect(find.text('查看歌手'), findsOneWidget);
      expect(find.byIcon(Icons.person_rounded), findsOneWidget);

      // 点击菜单项关闭菜单。
      await tester.tap(find.text('查看歌手'));
      await tester.pumpAndSettle();
      expect(find.text('下一首播放'), findsNothing);
    });

    testWidgets('当前播放歌曲显示行底色高亮与 NowPlayingBadge', (tester) async {
      final player = _FakePlayerController()
        ..currentSong = _song
        ..isPlaying = true;

      await tester.pumpWidget(
        wrap(buildRow(onPlay: (_, _) {}, player: player)),
      );
      // NowPlayingBadge 有持续动画，不能 pumpAndSettle
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.byType(NowPlayingBadge), findsOneWidget);

      final container = tester.widget<AnimatedContainer>(
        find
            .ancestor(
              of: find.byType(NowPlayingBadge),
              matching: find.byType(AnimatedContainer),
            )
            .first,
      );
      final decoration = container.decoration! as BoxDecoration;
      expect(decoration.color, isNotNull);
      expect(decoration.color!.a, greaterThan(0));
      // 描边画在 foregroundDecoration（不参与布局，保持行高与车机网格
      // rowCount * 60.0 的预留一致），断言随实现位置走。
      final foreground = container.foregroundDecoration! as BoxDecoration;
      expect(foreground.border, isNotNull);
    });

    testWidgets('非当前播放歌曲不渲染高亮底色与 Badge', (tester) async {
      await tester.pumpWidget(wrap(buildRow(onPlay: (_, _) {})));

      expect(find.byType(NowPlayingBadge), findsNothing);
    });

    testWidgets('正在播放歌曲在桌面端封面显示 4 柱跳动音波，点击触发暂停', (tester) async {
      final player = _FakePlayerController()
        ..currentSong = _song
        ..isPlaying = true;

      await tester.pumpWidget(
        wrap(buildRow(onPlay: (_, _) {}, player: player)),
      );
      await tester.pump(const Duration(milliseconds: 200));

      final coverBadgeFinder = find.byWidgetPredicate(
        (w) =>
            w is NowPlayingBadge && w.barCount == 4 && w.color == Colors.white,
      );
      expect(coverBadgeFinder, findsOneWidget);
      expect(find.byTooltip('暂停'), findsOneWidget);

      await tester.tap(coverBadgeFinder);
      await tester.pump(const Duration(milliseconds: 400));
      expect(player.togglePlayCount, 1);
      expect(player.isPlaying, isFalse);
    });

    testWidgets('当前歌曲处于暂停态时，桌面端悬停显示「继续播放」，点击触发播放恢复', (tester) async {
      final player = _FakePlayerController()
        ..currentSong = _song
        ..isPlaying = false;

      await tester.pumpWidget(
        wrap(buildRow(onPlay: (_, _) {}, player: player)),
      );

      // 未悬停时不可命中
      expect(find.byIcon(Icons.play_arrow_rounded).hitTestable(), findsNothing);

      // 模拟鼠标悬停到整行
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      await gesture.moveTo(tester.getCenter(find.byType(HomeSongRow)));
      await tester.pumpAndSettle();

      // 悬停后出现播放按钮且 tooltip 为「继续播放」
      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
      expect(find.byTooltip('继续播放'), findsOneWidget);

      // 点击触发 resume (player.togglePlay)
      await tester.tap(find.byIcon(Icons.play_arrow_rounded));
      await tester.pump(const Duration(milliseconds: 400));
      expect(player.togglePlayCount, 1);
      expect(player.isPlaying, isTrue);

      await gesture.removePointer();
    });

    testWidgets('非当前歌曲在桌面端悬停封面显示「播放」，点击调用 onPlay', (tester) async {
      final player = _FakePlayerController()
        ..currentSong = const Song(
          id: '2',
          title: '其他歌曲',
          artist: 'Other',
          duration: Duration(minutes: 3),
          hash: 'hash_other',
        )
        ..isPlaying = true;
      final playedSongs = <Song>[];

      await tester.pumpWidget(
        wrap(
          buildRow(
            player: player,
            onPlay: (song, queue) {
              playedSongs.add(song);
            },
          ),
        ),
      );

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      await gesture.moveTo(tester.getCenter(find.byType(HomeSongRow)));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
      expect(find.byTooltip('播放'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.play_arrow_rounded));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      expect(playedSongs, [_song]);
      expect(player.togglePlayCount, 0);

      await gesture.removePointer();
    });
  });

  group('首页歌曲行 移动端/车机端 (isDesktopFormFactor == false)', () {
    setUp(() {
      debugDesktopFormFactorOverride = false;
    });

    testWidgets('单击即播保持不变', (tester) async {
      var played = 0;
      await tester.pumpWidget(wrap(buildRow(onPlay: (_, _) => played++)));

      await tester.tap(find.text('海阔天空'));
      await tester.pump();

      expect(played, 1);
    });

    testWidgets('当前播放不整行染色，仅保留 Badge', (tester) async {
      final player = _FakePlayerController()
        ..currentSong = _song
        ..isPlaying = true;

      await tester.pumpWidget(
        wrap(buildRow(onPlay: (_, _) {}, player: player)),
      );
      // NowPlayingBadge 有持续动画，不能 pumpAndSettle
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.byType(NowPlayingBadge), findsOneWidget);

      final container = tester.widget<AnimatedContainer>(
        find
            .ancestor(
              of: find.byType(NowPlayingBadge),
              matching: find.byType(AnimatedContainer),
            )
            .first,
      );
      final decoration = container.decoration! as BoxDecoration;
      // 移动端整行底色保持透明（仅桌面加强高亮）。
      expect(decoration.color?.a ?? 0, 0);
      final foreground = container.foregroundDecoration! as BoxDecoration;
      final border = foreground.border as Border?;
      expect(border?.top.color.a ?? 0, 0);
    });
  });
}
