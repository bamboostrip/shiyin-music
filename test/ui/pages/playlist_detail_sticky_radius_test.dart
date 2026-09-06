import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyin_music/controllers/auth_controller.dart';
import 'package:shiyin_music/controllers/download_controller.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/controllers/theme_controller.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/services/music_api.dart';
import 'package:shiyin_music/ui/design_tokens.dart';
import 'package:shiyin_music/ui/form_factor.dart';
import 'package:shiyin_music/ui/pages/playlist_detail_page.dart';

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

Widget _wrapWithApp(Widget child) {
  return MaterialApp(
    home: Scaffold(
      body: child,
    ),
  );
}

Widget _buildTestStickyBar({
  double? topRadiusOverride,
  bool flatTop = false,
}) {
  return ListStickyBar(
    selecting: false,
    selectedCount: 0,
    allSelected: false,
    onToggleSelectAll: null,
    onDone: () {},
    title: '播放全部',
    subtitle: '共 10 首',
    canPlay: true,
    onPlay: () {},
    onSearch: () {},
    onSort: () {},
    selectEnabled: true,
    onSelect: () {},
    flatTop: flatTop,
    topRadiusOverride: topRadiusOverride,
  );
}

BoxDecoration _getStickyBarDecoration(WidgetTester tester) {
  final containerFinder = find.descendant(
    of: find.byType(ListStickyBar),
    matching: find.byType(Container),
  ).first;
  return tester.widget<Container>(containerFinder).decoration as BoxDecoration;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ListStickyBar 顶部圆角与阴影独立测试', () {
    testWidgets('topRadiusOverride 为 0 时为直角且无阴影', (tester) async {
      await tester.pumpWidget(_wrapWithApp(
        _buildTestStickyBar(topRadiusOverride: 0.0),
      ));

      final decoration = _getStickyBarDecoration(tester);
      expect(decoration.borderRadius, BorderRadius.zero);
      expect(decoration.boxShadow, isNull);
    });

    testWidgets('topRadiusOverride 为 16 时为圆角且有阴影', (tester) async {
      await tester.pumpWidget(_wrapWithApp(
        _buildTestStickyBar(topRadiusOverride: 16.0),
      ));

      final decoration = _getStickyBarDecoration(tester);
      expect(
        decoration.borderRadius,
        const BorderRadius.vertical(top: Radius.circular(16.0)),
      );
      expect(decoration.boxShadow, isNotNull);
      expect(decoration.boxShadow!.length, 1);
    });

    testWidgets('topRadiusOverride 为 8 时平滑插值为 8 且有阴影', (tester) async {
      await tester.pumpWidget(_wrapWithApp(
        _buildTestStickyBar(topRadiusOverride: 8.0),
      ));

      final decoration = _getStickyBarDecoration(tester);
      expect(
        decoration.borderRadius,
        const BorderRadius.vertical(top: Radius.circular(8.0)),
      );
      expect(decoration.boxShadow, isNotNull);
    });

    testWidgets('未传入 override 时，flatTop=true 表现为直角无阴影', (tester) async {
      await tester.pumpWidget(_wrapWithApp(
        _buildTestStickyBar(flatTop: true),
      ));

      final decoration = _getStickyBarDecoration(tester);
      expect(decoration.borderRadius, BorderRadius.zero);
      expect(decoration.boxShadow, isNull);
    });

    testWidgets('未传入 override 且 flatTop=false 表现为默认圆角 (AppRadius.lg) 且有阴影',
        (tester) async {
      await tester.pumpWidget(_wrapWithApp(
        _buildTestStickyBar(flatTop: false),
      ));

      final decoration = _getStickyBarDecoration(tester);
      expect(
        decoration.borderRadius,
        const BorderRadius.vertical(top: Radius.circular(AppRadius.lg)),
      );
      expect(decoration.boxShadow, isNotNull);
    });
  });

  group('PlaylistDetailPage 移动端滚动吸顶动态圆角集成测试', () {
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
      player = _FakePlayerController();
      auth = _FakeAuthController();
    });

    tearDown(() {
      debugDesktopFormFactorOverride = null;
    });

    Future<void> pumpPlaylistPage(WidgetTester tester, Size size) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: PlaylistDetailPage(
            api: api,
            auth: auth,
            player: player,
            playlist: playlist,
          ),
        ),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('移动端展开未吸顶时粘性条为 16px 圆角且有阴影', (tester) async {
      debugDesktopFormFactorOverride = false;
      await pumpPlaylistPage(tester, const Size(480, 850));

      final decoration = _getStickyBarDecoration(tester);
      expect(
        decoration.borderRadius,
        const BorderRadius.vertical(top: Radius.circular(16.0)),
      );
      expect(decoration.boxShadow, isNotNull);
    });

    testWidgets('移动端滚动吸顶后 (offset >= delta) 粘性条为直角且无阴影', (tester) async {
      debugDesktopFormFactorOverride = false;
      await pumpPlaylistPage(tester, const Size(480, 850));

      // 移动端 delta = 412 - 56 = 356。向下滚动 400 像素，使其完全吸顶。
      final scrollableFinder = find.byType(Scrollable).first;
      await tester.drag(scrollableFinder, const Offset(0, -400));
      await tester.pumpAndSettle();

      final decoration = _getStickyBarDecoration(tester);
      expect(decoration.borderRadius, BorderRadius.zero);
      expect(decoration.boxShadow, isNull);
    });

    testWidgets('移动端滚动到过渡区 (delta - 8) 时平滑插值为 8px 圆角', (tester) async {
      debugDesktopFormFactorOverride = false;
      await pumpPlaylistPage(tester, const Size(480, 850));

      // delta = 356. delta - 8 = 348.
      final scrollableFinder = find.byType(Scrollable).first;
      await tester.drag(scrollableFinder, const Offset(0, -348));
      await tester.pump();

      final decoration = _getStickyBarDecoration(tester);
      expect(
        decoration.borderRadius,
        const BorderRadius.vertical(top: Radius.circular(8.0)),
      );
      expect(decoration.boxShadow, isNotNull);
    });

    testWidgets('桌面端 (isDesktopFormFactor == true) 保持直角无阴影', (tester) async {
      debugDesktopFormFactorOverride = true;
      await pumpPlaylistPage(tester, const Size(1280, 800));

      final decoration = _getStickyBarDecoration(tester);
      expect(decoration.borderRadius, BorderRadius.zero);
      expect(decoration.boxShadow, isNull);
    });
  });
}
