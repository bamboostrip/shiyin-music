import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/controllers/auth_controller.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/ui/form_factor.dart';
import 'package:shiyin_music/ui/widgets/home_song_row.dart';

class _FakePlayerController extends ChangeNotifier implements PlayerController {
  @override
  Song? currentSong;

  @override
  bool isPlaying = false;

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
