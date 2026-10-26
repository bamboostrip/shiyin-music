// 歌单详情页「元信息 count 与可播放条数不一致」的解释提示（issue #6-1）：
// 530 首收藏里有 16 首无 hash（下架/无版权）被客户端过滤；全量加载完成后
// 列表上方必须显式告知，避免用户误以为「只加载了 514 首」。
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

List<Song> _playableSongs(int count) => List.generate(
      count,
      (index) => Song(
        id: 'song_$index',
        title: '歌曲$index',
        artist: '歌手',
        hash: 'hash_$index',
      ),
    );

/// 分页 fake：首页 50 条原始数据（2 条无 hash 被过滤），全量返回 514 首
/// 可播放曲目、原始条数 530（= 514 + 16 首下架/无版权）。
class _FakeMusicApi implements MusicApi {
  _FakeMusicApi({required this.songCount, required this.unavailableCount});

  final int songCount;
  final int unavailableCount;
  late final List<Song> playable = _playableSongs(songCount - unavailableCount);

  @override
  Future<SongPage> playlistSongPage(
    String id, {
    int page = 1,
    int pageSize = 80,
  }) async {
    final start = (page - 1) * pageSize;
    final songs = playable.skip(start).take(pageSize).toList();
    return SongPage(
      songs: songs,
      rawItemCount: page == 1 ? pageSize : songs.length,
    );
  }

  @override
  Future<SongPage> playlistSongsPageAll(String id) async {
    return SongPage(songs: playable, rawItemCount: songCount);
  }

  @override
  Future<PlaylistSummary> playlistInfo(String id) async {
    return PlaylistSummary(id: id, title: '发生喜欢的音乐', songCount: songCount);
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
  Duration duration = Duration.zero;

  @override
  String? errorMessage;

  @override
  DownloadController? downloadController;

  @override
  final ValueNotifier<Duration> positionListenable =
      ValueNotifier<Duration>(Duration.zero);

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

void main() {
  const playlist = PlaylistSummary(
    id: 'pl_liked',
    title: '发生喜欢的音乐',
    songCount: 530,
  );

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    debugDesktopFormFactorOverride = false;
    ThemeController();
  });

  tearDown(() {
    debugDesktopFormFactorOverride = null;
  });

  Future<void> pumpPage(WidgetTester tester, _FakeMusicApi api) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlaylistDetailPage(
            api: api,
            auth: _FakeAuthController(),
            player: _FakePlayerController(),
            playlist: playlist,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // 全量预加载由 post-frame 回调启动，内部是多段 await 链（缓存读写 +
    // 网络 + 分片落盘）；pumpAndSettle 只等帧，不再多放几帧的话断言会
    // 落在「已加载 50 首」的中途状态上。
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  testWidgets('530 首元信息 / 514 首可播放：列表上方解释 16 首已下架', (tester) async {
    await pumpPage(
      tester,
      _FakeMusicApi(songCount: 530, unavailableCount: 16),
    );

    expect(find.text('514 首歌曲'), findsOneWidget);
    expect(
      find.text('16 首歌曲已下架或暂无版权，未在列表中显示'),
      findsOneWidget,
    );
    // 顶部元信息仍显示服务端总数 530（与「我的」页收藏卡片一致）。
    expect(find.textContaining('530 首'), findsWidgets);
  });

  testWidgets('count 与可播放条数相等时不出现多余提示', (tester) async {
    await pumpPage(
      tester,
      _FakeMusicApi(songCount: 514, unavailableCount: 0),
    );

    expect(find.text('514 首歌曲'), findsOneWidget);
    expect(
      find.textContaining('已下架或暂无版权'),
      findsNothing,
    );
  });
}
