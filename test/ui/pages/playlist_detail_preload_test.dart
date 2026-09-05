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

class _FakeMusicApi implements MusicApi {
  _FakeMusicApi(this.allSongs);

  final List<Song> allSongs;
  int playlistSongsCallCount = 0;

  @override
  Future<SongPage> playlistSongPage(
    String id, {
    int page = 1,
    int pageSize = 50,
  }) async {
    final start = (page - 1) * pageSize;
    final songs = allSongs.skip(start).take(pageSize).toList();
    return SongPage(songs: songs, rawItemCount: songs.length);
  }

  @override
  Future<List<Song>> playlistSongs(
    String id, {
    int page = 1,
    int pageSize = 80,
    bool fetchAll = false,
  }) async {
    playlistSongsCallCount++;
    return allSongs;
  }

  @override
  Future<PlaylistSummary> playlistInfo(String id) async {
    return PlaylistSummary(
      id: id,
      title: '测试歌单',
      songCount: allSongs.length,
    );
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

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ThemeController();
  });

  testWidgets('PlaylistDetailPage 第一页加载完成后后台静默预加载全量歌曲', (tester) async {
    final songs = List.generate(
      120,
      (i) => Song(
        id: 's_$i',
        title: '歌曲 $i',
        artist: '歌手 $i',
        albumName: '专辑',
        duration: const Duration(minutes: 3),
        hash: 'hash_$i',
      ),
    );

    final api = _FakeMusicApi(songs);
    final player = _FakePlayerController();
    final auth = _FakeAuthController();
    const summary = PlaylistSummary(id: 'pl_test', title: '测试歌单', songCount: 120);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlaylistDetailPage(
            api: api,
            auth: auth,
            player: player,
            playlist: summary,
          ),
        ),
      ),
    );

    // 等待第 1 页渲染
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // PostFrameCallback 静默触发 _loadAllSongs(silent: true)
    await tester.pumpAndSettle();

    // 验证 playlistSongs (全量加载) 已在后台静默调用
    expect(api.playlistSongsCallCount, greaterThanOrEqualTo(1));
  });
}
