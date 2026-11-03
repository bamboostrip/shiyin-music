// 「显示已下架/无版权歌曲」设置在歌单详情页的落地行为（issue #6 用户诉求）：
//   1. 关闭（默认）：列表只展示可播放曲目，提示「未在列表中显示」；
//   2. 打开：按接口原始顺序置灰展示全部曲目，提示「已置灰显示」；
//   3. 置灰行带「已下架」微标，点击不播放、只弹提示；
//   4. 「播放全部/点歌」队列仍然只含可播放曲目，下架曲不会混进队列。
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
import 'package:shiyin_music/ui/widgets/app_song_row.dart';
import 'package:shiyin_music/ui/widgets/toast.dart';

Song _playable(int index) => Song(
  id: 'p_$index',
  title: '可播$index',
  artist: '歌手',
  hash: 'hash_$index',
);

Song _unavailable(int index) => Song(
  id: 'u_$index',
  title: '下架$index',
  artist: '歌手',
  hash: '',
);

/// 原始顺序：可播0 / 下架0 / 可播1 / 下架1 / 可播2（模拟歌单中间夹着下架曲）。
final List<Song> _orderedSongs = [
  _playable(0),
  _unavailable(0),
  _playable(1),
  _unavailable(1),
  _playable(2),
];

final List<Song> _playableSongs = _orderedSongs
    .where((song) => song.hash.isNotEmpty)
    .toList();

class _FakeMusicApi implements MusicApi {
  @override
  Future<SongPage> playlistSongPage(
    String id, {
    int page = 1,
    int pageSize = 80,
    bool includeShieldedMeta = false,
    String? listId,
  }) async {
    if (page > 1) {
      return const SongPage(songs: [], rawItemCount: 0);
    }
    return SongPage(
      songs: _playableSongs,
      rawItemCount: _orderedSongs.length,
      allSongs: _orderedSongs,
    );
  }

  @override
  Future<SongPage> playlistSongsPageAll(
    String id, {
    bool includeShieldedMeta = false,
    String? listId,
  }) async {
    return SongPage(
      songs: _playableSongs,
      rawItemCount: _orderedSongs.length,
      allSongs: _orderedSongs,
    );
  }

  @override
  Future<PlaylistSummary> playlistInfo(String id) async {
    return PlaylistSummary(
      id: id,
      title: '我的收藏',
      songCount: _orderedSongs.length,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakePlayerController extends ChangeNotifier
    implements PlayerController {
  @override
  bool showUnavailableSongs = false;

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
  String? lastPlaybackFailureToast;

  @override
  DownloadController? downloadController;

  @override
  final ValueNotifier<Duration> positionListenable =
      ValueNotifier<Duration>(Duration.zero);

  /// 记录起播调用：[song] 与传入的队列快照。
  final List<(Song, List<Song>?)> playCalls = [];

  @override
  Future<void> playSong(
    Song song, {
    List<Song>? queue,
    bool isRetry = false,
    Duration? initialPosition,
    bool preserveClimax = false,
    bool preservePersonalFmSession = false,
  }) async {
    playCalls.add((song, queue));
  }

  @override
  Future<void> togglePlay() async {}

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

Finder _rowFor(String title) => find.byWidgetPredicate(
  (widget) => widget is AppSongRow && widget.song.title == title,
  description: '歌曲行「$title」',
);

void main() {
  const playlist = PlaylistSummary(
    id: 'pl_liked',
    title: '我的收藏',
    songCount: 5,
  );

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    debugDesktopFormFactorOverride = false;
    ThemeController();
  });

  tearDown(() {
    debugDesktopFormFactorOverride = null;
  });

  Future<_FakePlayerController> pumpPage(
    WidgetTester tester, {
    required bool showUnavailable,
  }) async {
    final player = _FakePlayerController()
      ..showUnavailableSongs = showUnavailable;
    tester.view.physicalSize = const Size(400, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: Toast.navigatorKey,
        home: Scaffold(
          body: PlaylistDetailPage(
            api: _FakeMusicApi(),
            auth: _FakeAuthController(),
            player: player,
            playlist: playlist,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    return player;
  }

  testWidgets('默认隐藏：只显示可播放曲目，提示未在列表中显示', (tester) async {
    await pumpPage(tester, showUnavailable: false);

    expect(find.byType(AppSongRow), findsNWidgets(_playableSongs.length));
    expect(_rowFor('下架0'), findsNothing);
    expect(_rowFor('下架1'), findsNothing);
    expect(
      find.text('2 首歌曲已下架或暂无版权，未在列表中显示'),
      findsOneWidget,
    );
    expect(find.text('已下架'), findsNothing);
  });

  testWidgets('开启后按原始顺序置灰显示，并标注已下架', (tester) async {
    await pumpPage(tester, showUnavailable: true);

    final rows = tester
        .widgetList<AppSongRow>(find.byType(AppSongRow))
        .map((row) => row.song.title)
        .toList();
    expect(rows, ['可播0', '下架0', '可播1', '下架1', '可播2']);
    expect(find.text('已下架'), findsNWidgets(2));
    expect(
      find.text('2 首歌曲已下架或暂无版权，已置灰显示'),
      findsOneWidget,
    );

    final unavailableRows = tester
        .widgetList<AppSongRow>(find.byType(AppSongRow))
        .where((row) => row.song.hash.isEmpty);
    expect(unavailableRows.every((row) => row.unavailable), isTrue);
    final playableRows = tester
        .widgetList<AppSongRow>(find.byType(AppSongRow))
        .where((row) => row.song.hash.isNotEmpty);
    expect(playableRows.every((row) => !row.unavailable), isTrue);
  });

  testWidgets('设置切换后已打开的歌单页即时生效（桌面分区保活场景）', (tester) async {
    final player = await pumpPage(tester, showUnavailable: false);
    expect(_rowFor('下架0'), findsNothing);

    // 设置页拨动开关 → PlayerController.notifyListeners，本页监听并重建。
    player.showUnavailableSongs = true;
    player.notifyListeners();
    await tester.pump();

    expect(_rowFor('下架0'), findsOneWidget);
    expect(find.text('已下架'), findsNWidgets(2));
  });

  testWidgets('点击置灰行只弹提示，不发起播放', (tester) async {
    final player = await pumpPage(tester, showUnavailable: true);

    await tester.tap(_rowFor('下架0'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(player.playCalls, isEmpty);
    expect(
      find.text('该歌曲已下架或暂无版权，可在搜索中寻找其他版本'),
      findsOneWidget,
    );

    // 等 Toast 自动消失，避免测试结束时留下未完成 Timer。
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
  });

  testWidgets('点可播曲目起播：队列只含可播放曲目，下架曲不混入', (tester) async {
    final player = await pumpPage(tester, showUnavailable: true);

    await tester.tap(_rowFor('可播1'));
    await tester.pump();

    expect(player.playCalls, hasLength(1));
    final (started, queue) = player.playCalls.single;
    expect(started.title, '可播1');
    expect(queue, isNotNull);
    expect(
      queue!.map((song) => song.hash).toList(),
      _playableSongs.map((song) => song.hash).toList(),
    );
    expect(queue.every((song) => song.hash.isNotEmpty), isTrue);
  });
}
