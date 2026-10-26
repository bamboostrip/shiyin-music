// PlaylistDetailPage 通用静态集合 + readOnly（上游 f230444 的 initialSongs /
// readOnly 在 fork 上的适配）：
// - initialSongs 非空即静态集合：直接用传入歌曲填充，不请求分页/全量/详情/
//   相似歌单；readOnly 时隐藏收藏/多选/更多入口，只保留播放、搜索、排序；
// - 每日推荐携带 initialSongs 时也走同一通用分支（回归：不再请求 dailyRecommend）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyin_music/controllers/auth_controller.dart';
import 'package:shiyin_music/controllers/download_controller.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/controllers/theme_controller.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/services/music_api.dart';
import 'package:shiyin_music/ui/pages/playlist_detail_page.dart';

class _RecordingApi implements MusicApi {
  int playlistSongPageCalls = 0;
  int playlistSongsCalls = 0;
  int playlistInfoCalls = 0;
  int similarPlaylistsCalls = 0;
  int dailyRecommendCalls = 0;

  @override
  Future<SongPage> playlistSongPage(
    String id, {
    int page = 1,
    int pageSize = 50,
  }) async {
    playlistSongPageCalls++;
    throw StateError('静态集合不应请求分页歌曲');
  }

  @override
  Future<List<Song>> playlistSongs(
    String id, {
    int page = 1,
    int pageSize = 80,
    bool fetchAll = false,
  }) async {
    playlistSongsCalls++;
    throw StateError('静态集合不应请求全量歌曲');
  }

  @override
  Future<PlaylistSummary> playlistInfo(String id) async {
    playlistInfoCalls++;
    throw StateError('静态集合不应请求歌单详情');
  }

  @override
  Future<List<PlaylistSummary>> similarPlaylists(String ids) async {
    similarPlaylistsCalls++;
    throw StateError('静态集合不应请求相似歌单');
  }

  @override
  Future<DailyRecommend> dailyRecommend() async {
    dailyRecommendCalls++;
    throw StateError('携带 initialSongs 的每日推荐不应再请求接口');
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
  DownloadController? downloadController;

  @override
  Duration position = Duration.zero;

  @override
  Duration duration = Duration.zero;

  @override
  String? errorMessage;

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

List<Song> _songs() => List.generate(
      3,
      (i) => Song(
        id: 's_$i',
        title: '推荐歌曲 $i',
        artist: '歌手 $i',
        hash: 'hash_$i',
        duration: const Duration(minutes: 3),
      ),
    );

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ThemeController();
  });

  Future<_RecordingApi> pumpStaticCollection(
    WidgetTester tester, {
    required PlaylistSummary playlist,
    required List<Song> songs,
    bool readOnly = true,
  }) async {
    final api = _RecordingApi();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlaylistDetailPage(
            api: api,
            auth: _FakeAuthController(),
            player: _FakePlayerController(),
            playlist: playlist,
            initialSongs: songs,
            readOnly: readOnly,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return api;
  }

  testWidgets('静态集合：直接用 initialSongs 展示，不请求任何歌单接口', (tester) async {
    final api = await pumpStaticCollection(
      tester,
      playlist: const PlaylistSummary(
        id: 'recommended-card-1',
        title: '私人专属好歌',
        subtitle: '根据你的口味精选',
        songCount: 3,
      ),
      songs: _songs(),
    );

    expect(find.text('推荐歌曲 0'), findsOneWidget);
    expect(find.text('推荐歌曲 2'), findsOneWidget);
    // 总数文案来自入口歌曲，不等待网络。
    expect(find.text('3 首歌曲'), findsOneWidget);
    expect(api.playlistSongPageCalls, 0);
    expect(api.playlistSongsCalls, 0);
    expect(api.playlistInfoCalls, 0);
    expect(api.similarPlaylistsCalls, 0);
  });

  testWidgets('readOnly：隐藏收藏/多选/更多入口，保留播放/搜索/排序', (tester) async {
    await pumpStaticCollection(
      tester,
      playlist: const PlaylistSummary(
        id: 'recommended-card-2',
        title: '经典怀旧金曲',
        songCount: 3,
      ),
      songs: _songs(),
    );

    expect(find.text('收藏'), findsNothing);
    expect(find.byTooltip('更多'), findsNothing);
    expect(find.byTooltip('多选'), findsNothing);
    expect(find.byTooltip('搜索'), findsOneWidget);
    expect(find.byTooltip('排序'), findsOneWidget);
  });

  testWidgets('每日推荐携带 initialSongs：复用静态集合分支，不再请求 dailyRecommend', (tester) async {
    final api = await pumpStaticCollection(
      tester,
      playlist: const PlaylistSummary(
        id: 'daily_recommend',
        title: '每日推荐',
        songCount: 3,
      ),
      songs: _songs(),
      readOnly: false,
    );

    expect(find.text('每日推荐'), findsWidgets);
    expect(find.text('推荐歌曲 1'), findsOneWidget);
    expect(api.dailyRecommendCalls, 0);
    expect(api.playlistSongPageCalls, 0);
    expect(api.playlistSongsCalls, 0);
    expect(api.similarPlaylistsCalls, 0);
  });
}
