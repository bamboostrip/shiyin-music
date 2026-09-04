import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/controllers/auth_controller.dart';
import 'package:shiyin_music/controllers/download_controller.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/ui/form_factor.dart';
import 'package:shiyin_music/ui/pages/search_song_results.dart';
import 'package:shiyin_music/ui/widgets/desktop_song_table_row.dart';

class _FakePlayerController extends ChangeNotifier implements PlayerController {
  @override
  Song? currentSong;

  @override
  bool isPlaying = false;

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

const _kugouSong = Song(
  id: '1',
  title: '海阔天空',
  artist: 'Beyond',
  albumName: '乐与怒',
  duration: Duration(seconds: 325),
  hash: 'hash_haiKuoTianKong',
);

const _neteaseSong = Song(
  id: '2',
  title: ' external song',
  artist: 'External Artist',
  albumName: 'External Album',
  duration: Duration(seconds: 200),
  hash: 'hash_external',
  source: SongSource.netease,
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

  Widget buildResults({
    required List<Song> songs,
    required void Function(Song song) onPlay,
  }) {
    final player = _FakePlayerController();
    final auth = _FakeAuthController();
    return SearchSongResults(
      songs: songs,
      onPlay: onPlay,
      isLiked: (song) => false,
      onLikeTap: (_) {},
      auth: auth,
      player: player,
      onViewArtist: (_) {},
    );
  }

  group('SearchSongResults 桌面端表格 (isDesktopFormFactor == true)', () {
    setUp(() {
      debugDesktopFormFactorOverride = true;
    });

    testWidgets('渲染表头与固定 44px 高度的数据行（歌曲/歌手/专辑/时长）', (tester) async {
      var played = 0;
      await tester.pumpWidget(
        wrap(
          buildResults(
            songs: [_kugouSong, _neteaseSong],
            onPlay: (_) => played++,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(DesktopSongTableHeader), findsOneWidget);
      expect(find.text('歌曲标题'), findsOneWidget);
      expect(find.text('歌手'), findsOneWidget);
      expect(find.text('专辑'), findsOneWidget);
      expect(find.text('时长'), findsOneWidget);

      expect(find.byType(DesktopSongTableRow), findsNWidgets(2));
      expect(find.text('海阔天空'), findsOneWidget);
      expect(find.text('Beyond'), findsOneWidget);
      expect(find.text('乐与怒'), findsOneWidget);
      expect(find.text('05:25'), findsOneWidget);

      final rowSize = tester.getSize(find.byType(DesktopSongTableRow).first);
      expect(rowSize.height, 44.0);
      expect(played, 0);
    });

    testWidgets('双击行触发播放，单击不触发播放', (tester) async {
      var played = 0;
      await tester.pumpWidget(
        wrap(buildResults(songs: [_kugouSong], onPlay: (_) => played++)),
      );
      await tester.pumpAndSettle();

      final rowTopLeft = tester.getTopLeft(find.byType(DesktopSongTableRow));
      final pressPoint = rowTopLeft + const Offset(100, 22);

      // 单击：等待双击超时后仍不应播放
      await tester.tapAt(pressPoint);
      await tester.pump(const Duration(milliseconds: 350));
      expect(played, 0);

      // 双击：触发播放
      await tester.tapAt(pressPoint);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(pressPoint);
      await tester.pumpAndSettle();
      expect(played, 1);
    });

    testWidgets('右键行弹出 anchored 操作菜单', (tester) async {
      await tester.pumpWidget(
        wrap(buildResults(songs: [_kugouSong], onPlay: (_) {})),
      );
      await tester.pumpAndSettle();

      final rowTopLeft = tester.getTopLeft(find.byType(DesktopSongTableRow));
      await tester.tapAt(
        rowTopLeft + const Offset(100, 22),
        buttons: kSecondaryButton,
      );
      await tester.pumpAndSettle();

      expect(find.text('下一首播放'), findsOneWidget);
    });

    testWidgets('外部平台歌曲行悬停不显示操作图标，菜单仅播放类操作', (tester) async {
      await tester.pumpWidget(
        wrap(buildResults(songs: [_neteaseSong], onPlay: (_) {})),
      );
      await tester.pumpAndSettle();

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      await gesture.moveTo(tester.getCenter(find.byType(DesktopSongTableRow)));
      await tester.pumpAndSettle();

      expect(find.text('00:00').evaluate(), isEmpty);
      expect(find.text('03:20'), findsOneWidget);
      expect(find.byIcon(Icons.favorite_border_rounded), findsNothing);
      expect(find.byIcon(Icons.more_horiz_rounded), findsNothing);
      await gesture.removePointer();

      // 右键菜单只保留「下一首播放」，无收藏/歌单/下载操作
      final rowTopLeft = tester.getTopLeft(find.byType(DesktopSongTableRow));
      await tester.tapAt(
        rowTopLeft + const Offset(100, 22),
        buttons: kSecondaryButton,
      );
      await tester.pumpAndSettle();

      expect(find.text('下一首播放'), findsOneWidget);
      expect(find.text('添加到歌单'), findsNothing);
      expect(find.text('查看歌手'), findsNothing);
    });
  });

  group('SearchSongResults 移动端/车机端 (isDesktopFormFactor == false)', () {
    setUp(() {
      debugDesktopFormFactorOverride = false;
    });

    testWidgets('保持卡片行单击即播，不渲染桌面表格', (tester) async {
      var played = 0;
      await tester.pumpWidget(
        wrap(buildResults(songs: [_kugouSong], onPlay: (_) => played++)),
      );
      await tester.pumpAndSettle();

      expect(find.byType(DesktopSongTableRow), findsNothing);
      expect(find.byType(DesktopSongTableHeader), findsNothing);

      await tester.tap(find.text('海阔天空'));
      await tester.pumpAndSettle();
      expect(played, 1);
    });
  });
}
