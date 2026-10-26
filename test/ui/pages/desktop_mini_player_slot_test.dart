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
import 'package:shiyin_music/ui/widgets/mini_player.dart';

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

  @override
  Future<SongPage> playlistSongsPageAll(String id) async {
    return SongPage(songs: allSongs, rawItemCount: allSongs.length);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakePlayerController extends ChangeNotifier
    implements PlayerController {
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
  bool isPlaying = false;

  @override
  bool isPreparing = false;

  @override
  Duration position = Duration.zero;

  @override
  Duration duration = const Duration(minutes: 4);

  @override
  String? errorMessage;

  @override
  DownloadController? downloadController;

  @override
  final ValueNotifier<Duration> positionListenable =
      ValueNotifier<Duration>(Duration.zero);

  void play(Song song, List<Song> newQueue) {
    currentSong = song;
    queue = newQueue;
    notifyListeners();
  }

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

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ThemeController();
    songs = generateSongs(60);
    api = _FakeMusicApi(songs);
    player = _FakePlayerController()..play(songs[0], songs);
    auth = _FakeAuthController();
  });

  tearDown(() {
    debugDesktopFormFactorOverride = null;
  });

  Widget buildSlot() {
    return MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: MiniPlayerSlot(player: player, auth: auth),
        ),
      ),
    );
  }

  group('MiniPlayerSlot 双形态门控', () {
    testWidgets('桌面形态不挂载迷你播放条（PC 只保留底部 DesktopPlayerBar）', (tester) async {
      debugDesktopFormFactorOverride = true;

      await tester.pumpWidget(buildSlot());
      await tester.pump();

      expect(find.byType(MiniPlayer), findsNothing);
      expect(find.text('歌曲00'), findsNothing);
    });

    testWidgets('移动端形态挂载迷你播放条（行为与改造前一致）', (tester) async {
      debugDesktopFormFactorOverride = false;

      await tester.pumpWidget(buildSlot());
      await tester.pump();

      expect(find.byType(MiniPlayer), findsOneWidget);
      expect(find.text('歌曲00'), findsOneWidget);
    });
  });

  group('PlaylistDetailPage 播放条不重复', () {
    Widget buildPage() {
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
      await tester.pumpWidget(buildPage());
      await tester.pumpAndSettle();
    }

    testWidgets('桌面端播放中进入歌单详情：不渲染悬浮 MiniPlayer，定位按钮贴底',
        (tester) async {
      debugDesktopFormFactorOverride = true;
      await pumpPage(tester, const Size(1280, 800));

      // 关键回归点：内容区底部已有常驻 DesktopPlayerBar，
      // 歌单详情不得再挂一条悬浮迷你播放条。
      expect(find.byType(MiniPlayer), findsNothing);

      // 定位按钮仍在，只是不再需要为迷你播放条让位（bottom 16）。
      expect(find.byType(LocateCurrentSongButton), findsOneWidget);
      final rect = tester.getRect(find.byType(LocateCurrentSongButton));
      expect(rect.bottom, closeTo(800 - 16, 1));
    });

    testWidgets('移动端播放中进入歌单详情：仍渲染悬浮 MiniPlayer，定位按钮抬到其上方',
        (tester) async {
      debugDesktopFormFactorOverride = false;
      await pumpPage(tester, const Size(480, 850));

      expect(find.byType(MiniPlayer), findsOneWidget);
      expect(find.byType(LocateCurrentSongButton), findsOneWidget);

      // 移动端预留：60（迷你条）+ 10（底部间距）+ 8（间隙）
      final rect = tester.getRect(find.byType(LocateCurrentSongButton));
      expect(rect.bottom, closeTo(850 - (60 + 10 + 8), 1));
    });
  });
}