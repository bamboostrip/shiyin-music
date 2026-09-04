import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyin_music/controllers/auth_controller.dart';
import 'package:shiyin_music/controllers/download_controller.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/controllers/theme_controller.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/services/music_api.dart';
import 'package:shiyin_music/ui/form_factor.dart';
import 'package:shiyin_music/ui/pages/playlist_detail_page.dart';
import 'package:shiyin_music/ui/widgets/locate_current_song_button.dart';

/// 分页 fake：按 page/pageSize 切片返回。
class _FakeMusicApi implements MusicApi {
  _FakeMusicApi(this.allSongs);

  final List<Song> allSongs;

  @override
  Future<SongPage> playlistSongPage(
    String id, {
    int page = 1,
    int pageSize = 80,
  }) async {
    final start = (page - 1) * pageSize;
    final songs = allSongs.skip(start).take(pageSize).toList();
    return SongPage(songs: songs, rawItemCount: songs.length);
  }

  @override
  Future<PlaylistSummary> playlistInfo(String id) async {
    return PlaylistSummary(id: id, title: '测试歌单', songCount: allSongs.length);
  }

  // similarPlaylists 等未实现方法：页面内均 try/catch 静默降级。
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakePlayerController extends ChangeNotifier
    implements PlayerController {
  @override
  Song? currentSong;

  @override
  List<Song> queue = [];

  @override
  bool isPlaying = false;

  @override
  bool isPreparing = false;

  @override
  Duration position = Duration.zero;

  @override
  Duration duration = Duration.zero;

  @override
  String? errorMessage;

  @override
  DownloadController? downloadController;

  @override
  final ValueNotifier<Duration> positionListenable =
      ValueNotifier(Duration.zero);

  void play(Song song, List<Song> newQueue) {
    currentSong = song;
    queue = newQueue;
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeAuthController extends ChangeNotifier implements AuthController {
  @override
  PlaylistSummary? findUserPlaylist(PlaylistSummary playlist) => null;

  @override
  bool isPlaylistInLibrary(PlaylistSummary playlist) => false;

  @override
  bool canEditPlaylist(PlaylistSummary playlist) => false;

  @override
  bool isLiked(Song song) => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  const playlist = PlaylistSummary(id: 'pl_1', title: '测试歌单', songCount: 60);

  List<Song> generateSongs(int count) => List.generate(count, (i) {
        final n = i.toString().padLeft(2, '0');
        return Song(
          id: 'song_$n',
          title: '歌曲$n',
          artist: '歌手$n',
          hash: 'hash_$n',
          albumName: '专辑',
          duration: const Duration(minutes: 3),
        );
      });

  late List<Song> songs;
  late _FakeMusicApi api;
  late _FakePlayerController player;
  late _FakeAuthController auth;

  const outsiderSong = Song(
    id: 'song_outsider',
    title: '别的歌',
    artist: '别的歌手',
    hash: 'hash_outsider',
    albumName: '别的专辑',
    duration: Duration(minutes: 3),
  );

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ThemeController();
    songs = generateSongs(60);
    api = _FakeMusicApi(songs);
    player = _FakePlayerController();
    auth = _FakeAuthController();
  });

  tearDown(() {
    debugDesktopFormFactorOverride = null;
  });

  Widget buildSubject() {
    return MaterialApp(
      home: Scaffold(
        body: PlaylistDetailPage(
          api: api,
          auth: auth,
          player: player,
          playlist: playlist,
        ),
      ),
    );
  }

  Future<void> pumpPage(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(buildSubject());
    await tester.pumpAndSettle();
  }

  /// 歌曲行内的文本（限定在滚动列表内，排除底部 MiniPlayer 的歌名）。
  Finder rowText(String title) => find.descendant(
        of: find.byType(Scrollable),
        matching: find.text(title),
      );

  double scrollOffset(WidgetTester tester) => tester
      .state<ScrollableState>(find.byType(Scrollable).first)
      .position
      .pixels;

  group('PlaylistDetailPage 定位按钮 PC 桌面端 (isDesktopFormFactor == true)', () {
    testWidgets('进入歌单不自动定位：有播放歌曲也保持列表在顶部', (tester) async {
      // 当前播放第 56 首（深页，未加载），队列 = 完整歌单。
      player.play(songs[55], songs);
      await pumpPage(tester, const Size(1280, 800));

      expect(scrollOffset(tester), 0);
      expect(rowText('歌曲00'), findsOneWidget);
      expect(rowText('歌曲55'), findsNothing);
    });

    testWidgets('无播放歌曲不显示定位按钮', (tester) async {
      await pumpPage(tester, const Size(1280, 800));
      expect(find.byType(LocateCurrentSongButton), findsNothing);
    });

    testWidgets('播放歌曲不属于本歌单（队列不匹配）不显示定位按钮', (tester) async {
      player.play(outsiderSong, [outsiderSong]);
      await pumpPage(tester, const Size(1280, 800));
      expect(find.byType(LocateCurrentSongButton), findsNothing);
    });

    testWidgets('播放歌曲属于本歌单时显示按钮，点击滚动到目标行', (tester) async {
      // 第 40 首在首页已加载的 50 首里。
      player.play(songs[40], songs);
      await pumpPage(tester, const Size(1280, 800));

      expect(find.byType(LocateCurrentSongButton), findsOneWidget);
      expect(find.byTooltip('定位到当前播放'), findsOneWidget);
      expect(rowText('歌曲40'), findsNothing);

      await tester.tap(find.byType(LocateCurrentSongButton));
      await tester.pumpAndSettle();

      final rect = tester.getRect(rowText('歌曲40'));
      expect(rect.top, greaterThanOrEqualTo(0));
      expect(rect.bottom, lessThanOrEqualTo(800));
    });

    testWidgets('深页场景（队列匹配）点击按钮限量加载后定位成功', (tester) async {
      player.play(songs[55], songs);
      await pumpPage(tester, const Size(1280, 800));

      expect(find.byType(LocateCurrentSongButton), findsOneWidget);
      await tester.tap(find.byType(LocateCurrentSongButton));
      await tester.pumpAndSettle();

      final rect = tester.getRect(rowText('歌曲55'));
      expect(rect.top, greaterThanOrEqualTo(0));
      expect(rect.bottom, lessThanOrEqualTo(800));
    });

    testWidgets('切歌时按钮显隐跟随新歌（AnimatedBuilder 刷新，无需整页 setState）',
        (tester) async {
      player.play(songs[40], songs);
      await pumpPage(tester, const Size(1280, 800));
      expect(find.byType(LocateCurrentSongButton), findsOneWidget);

      // 切到别的歌单的歌：按钮消失。
      player.play(outsiderSong, [outsiderSong]);
      await tester.pump();
      expect(find.byType(LocateCurrentSongButton), findsNothing);

      // 再切回本歌单：按钮重新出现。
      player.play(songs[10], songs);
      await tester.pump();
      expect(find.byType(LocateCurrentSongButton), findsOneWidget);
    });

    testWidgets('多选模式下隐藏定位按钮（不与多选底栏重叠）', (tester) async {
      player.play(songs[40], songs);
      await pumpPage(tester, const Size(1280, 800));
      expect(find.byType(LocateCurrentSongButton), findsOneWidget);

      await tester.tap(find.byTooltip('多选'));
      await tester.pumpAndSettle();

      expect(find.byType(LocateCurrentSongButton), findsNothing);
    });
  });

  group('PlaylistDetailPage 定位按钮移动端 (isDesktopFormFactor == false)', () {
    // 480x850：普通手机宽度。更窄（如 412）时歌单头 Hero 操作区会溢出，
    // 属于与本任务无关的既有问题，测试不覆盖该宽度。
    testWidgets('进入歌单不自动定位，深页播放歌曲仍显示按钮', (tester) async {
      player.play(songs[55], songs);
      await pumpPage(tester, const Size(480, 850));

      expect(scrollOffset(tester), 0);
      expect(rowText('歌曲00'), findsOneWidget);
      expect(rowText('歌曲55'), findsNothing);
      expect(find.byType(LocateCurrentSongButton), findsOneWidget);
    });

    testWidgets('无播放歌曲不显示定位按钮', (tester) async {
      await pumpPage(tester, const Size(480, 850));
      expect(find.byType(LocateCurrentSongButton), findsNothing);
    });

    testWidgets('点击按钮深页限量加载后滚动到目标行', (tester) async {
      player.play(songs[55], songs);
      await pumpPage(tester, const Size(480, 850));

      await tester.tap(find.byType(LocateCurrentSongButton));
      await tester.pumpAndSettle();

      final rect = tester.getRect(rowText('歌曲55'));
      expect(rect.top, greaterThanOrEqualTo(0));
      expect(rect.bottom, lessThanOrEqualTo(850));
    });

    testWidgets('多选模式下隐藏定位按钮', (tester) async {
      player.play(songs[40], songs);
      await pumpPage(tester, const Size(480, 850));
      expect(find.byType(LocateCurrentSongButton), findsOneWidget);

      await tester.tap(find.byTooltip('多选'));
      await tester.pumpAndSettle();

      expect(find.byType(LocateCurrentSongButton), findsNothing);
    });
  });
}
