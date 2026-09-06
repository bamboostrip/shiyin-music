import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/controllers/auth_controller.dart';
import 'package:shiyin_music/controllers/download_controller.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/ui/form_factor.dart';
import 'package:shiyin_music/ui/widgets/home_song_row.dart';

class _FakePlayerController extends ChangeNotifier implements PlayerController {
  @override
  Song? currentSong;

  @override
  bool isPlaying = false;

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
  }) {
    return HomeSongRow(
      song: _song,
      queue: [_song],
      onPlay: onPlay,
      isLiked: false,
      onLikeTap: () {},
      auth: _FakeAuthController(),
      player: _FakePlayerController(),
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

      // 未悬停时不显示播放按钮
      expect(find.byIcon(Icons.play_arrow_rounded), findsNothing);

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
  });
}
