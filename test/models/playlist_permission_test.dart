import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/controllers/auth_controller.dart';
import 'package:shiyin_music/controllers/download_controller.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/models/music_models.dart';
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

class _TestAuthController extends ChangeNotifier implements AuthController {
  _TestAuthController({
    this.loggedIn = true,
    this.testUserId = 'user_123',
    this.userPlaylists = const [],
  });

  bool loggedIn;
  String? testUserId;
  List<PlaylistSummary> userPlaylists;

  @override
  bool get isLoggedIn => loggedIn;

  @override
  LoginSession? get session =>
      loggedIn && testUserId != null ? LoginSession(userId: testUserId) : null;

  @override
  List<PlaylistSummary> get playlists => userPlaylists;

  @override
  PlaylistSummary? findUserPlaylist(PlaylistSummary playlist) {
    for (final item in playlists) {
      if (item.id == playlist.id ||
          (playlist.listId != null && item.listId == playlist.listId) ||
          (item.sourceGlobalId != null && item.sourceGlobalId == playlist.id) ||
          (playlist.sourceGlobalId != null &&
              item.sourceGlobalId == playlist.sourceGlobalId)) {
        return item;
      }
    }
    return null;
  }

  @override
  bool isPlaylistInLibrary(PlaylistSummary playlist) =>
      findUserPlaylist(playlist) != null;

  @override
  bool canEditPlaylist(PlaylistSummary playlist) {
    if (!isLoggedIn) return false;
    final item = findUserPlaylist(playlist);
    if (item != null) {
      return item.canEditTracks;
    }
    final myUserId = session?.userId;
    if (myUserId != null &&
        myUserId.isNotEmpty &&
        playlist.creatorUserId != null &&
        playlist.creatorUserId!.isNotEmpty &&
        myUserId == playlist.creatorUserId) {
      return playlist.canEditTracks;
    }
    return false;
  }

  @override
  bool isLiked(Song song) => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _testSong = Song(
  id: 'song_1',
  title: '过火',
  artist: '张信哲',
  albumName: '宽容',
  duration: Duration(minutes: 5, seconds: 2),
  hash: 'hash_guohuo',
);

void main() {
  group('PlaylistSummary 创作者与可编辑权限判定', () {
    test('公共/推荐歌单即便 isDefault==0 也不能判定为用户自建歌单', () {
      const publicPlaylist = PlaylistSummary(
        id: 'pub_1',
        title: '8090后经典老歌400首',
        creatorName: 'DJ桃桃乌龙',
        creatorUserId: 'other_user_888',
        isDefault: 0,
      );

      expect(publicPlaylist.isCreatedPlaylist, isFalse);
      expect(publicPlaylist.canEditTracks, isFalse);
    });

    test('用户自建歌单（type==0）判定为自建且可编辑曲目', () {
      const myCreated = PlaylistSummary(
        id: 'my_1',
        title: '我的歌单1',
        type: 0,
        isDefault: 0,
      );

      expect(myCreated.isCreatedPlaylist, isTrue);
      expect(myCreated.canEditTracks, isTrue);
    });

    test('用户收藏的他人的歌单（type==1）不能编辑曲目', () {
      const collected = PlaylistSummary(
        id: 'col_1',
        title: '收藏别人的歌单',
        type: 1,
        isDefault: 0,
      );

      expect(collected.isCreatedPlaylist, isFalse);
      expect(collected.canEditTracks, isFalse);
    });

    test('「我喜欢」歌单可编辑曲目', () {
      const liked = PlaylistSummary(
        id: 'liked_1',
        title: '我喜欢',
        isDefault: 2,
      );

      expect(liked.isLikedPlaylist, isTrue);
      expect(liked.canEditTracks, isTrue);
    });

    test('匹配 creatorUserId == currentUserId 时判定为自建', () {
      const matching = PlaylistSummary(
        id: 'match_1',
        title: '某歌单',
        creatorUserId: 'user_123',
        currentUserId: 'user_123',
      );

      expect(matching.isCreatedPlaylist, isTrue);
      expect(matching.canEditTracks, isTrue);
    });

    test('不匹配 creatorUserId != currentUserId 时不判定为自建', () {
      const mismatch = PlaylistSummary(
        id: 'mismatch_1',
        title: '某歌单',
        creatorUserId: 'other_456',
        currentUserId: 'user_123',
      );

      expect(mismatch.isCreatedPlaylist, isFalse);
      expect(mismatch.canEditTracks, isFalse);
    });
  });

  group('AuthController.canEditPlaylist 鉴权', () {
    test('未登录用户一律不可编辑任何歌单', () {
      final auth = _TestAuthController(loggedIn: false);
      const playlist = PlaylistSummary(id: 'pl_1', title: '歌单', type: 0);

      expect(auth.canEditPlaylist(playlist), isFalse);
    });

    test('点击推荐或他人公共歌单（不在用户库中）不可编辑曲目', () {
      final auth = _TestAuthController(
        loggedIn: true,
        testUserId: 'user_123',
        userPlaylists: [
          const PlaylistSummary(id: 'my_1', title: '我的歌单', type: 0),
        ],
      );
      const publicPlaylist = PlaylistSummary(
        id: '8090_classic',
        title: '8090后经典老歌400首',
        creatorName: 'DJ桃桃乌龙',
        creatorUserId: 'other_user_999',
        isDefault: 0,
      );

      expect(auth.canEditPlaylist(publicPlaylist), isFalse);
    });

    test('自建歌单（在用户库中，type==0）可编辑曲目', () {
      const myPlaylist = PlaylistSummary(id: 'my_1', title: '我的歌单', type: 0);
      final auth = _TestAuthController(
        loggedIn: true,
        testUserId: 'user_123',
        userPlaylists: [myPlaylist],
      );

      expect(auth.canEditPlaylist(myPlaylist), isTrue);
    });

    test('收藏他人的歌单（在用户库中，type==1）不可编辑曲目', () {
      const collectedPlaylist = PlaylistSummary(
        id: 'col_1',
        title: '收藏别人的歌单',
        type: 1,
      );
      final auth = _TestAuthController(
        loggedIn: true,
        testUserId: 'user_123',
        userPlaylists: [collectedPlaylist],
      );

      expect(auth.canEditPlaylist(collectedPlaylist), isFalse);
    });
  });

  group('DesktopSongTableRow 删除按钮展示控制', () {
    Widget wrap(Widget child) {
      return MaterialApp(
        home: Scaffold(
          body: SizedBox(width: 900, child: child),
        ),
      );
    }

    testWidgets('canDelete 为 false（他人的歌单）时悬停展示更多图标而不是删除垃圾桶图标',
        (tester) async {
      final player = _FakePlayerController();
      final auth = _TestAuthController();

      await tester.pumpWidget(
        wrap(
          DesktopSongTableRow(
            song: _testSong,
            index: 1,
            player: player,
            auth: auth,
            canDelete: false, // 他人的歌单
            selecting: false,
            selected: false,
            isFocused: false,
            onTap: () {},
            onDoubleTap: () {},
            onPlay: () {},
            onAddToPlaylist: () {},
            onDelete: () {},
            onViewArtist: () {},
            onMore: () {},
          ),
        ),
      );

      // 模拟鼠标悬停
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      await gesture.moveTo(tester.getCenter(find.byType(DesktopSongTableRow)));
      await tester.pumpAndSettle();

      // 他人歌单：绝不展示「从歌单删除」垃圾桶图标
      expect(find.byIcon(Icons.delete_outline_rounded), findsNothing);
      expect(find.byTooltip('从歌单删除'), findsNothing);

      // 展示「更多」菜单图标
      expect(find.byIcon(Icons.more_horiz_rounded), findsOneWidget);
      expect(find.byTooltip('更多'), findsOneWidget);

      await gesture.removePointer();
    });

    testWidgets('canDelete 为 true（自建歌单）时悬停展示「从歌单删除」垃圾桶图标',
        (tester) async {
      final player = _FakePlayerController();
      final auth = _TestAuthController();
      var deleteCalled = false;

      await tester.pumpWidget(
        wrap(
          DesktopSongTableRow(
            song: _testSong,
            index: 1,
            player: player,
            auth: auth,
            canDelete: true, // 自建歌单
            selecting: false,
            selected: false,
            isFocused: false,
            onTap: () {},
            onDoubleTap: () {},
            onPlay: () {},
            onAddToPlaylist: () {},
            onDelete: () => deleteCalled = true,
            onViewArtist: () {},
            onMore: () {},
          ),
        ),
      );

      // 模拟鼠标悬停
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      await gesture.moveTo(tester.getCenter(find.byType(DesktopSongTableRow)));
      await tester.pumpAndSettle();

      // 自建歌单：展示「从歌单删除」垃圾桶图标
      final deleteIcon = find.byIcon(Icons.delete_outline_rounded);
      expect(deleteIcon, findsOneWidget);
      expect(find.byTooltip('从歌单删除'), findsOneWidget);

      await tester.tap(deleteIcon);
      await tester.pumpAndSettle();
      expect(deleteCalled, isTrue);

      await gesture.removePointer();
    });
  });
}
