import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/controllers/auth_controller.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/ui/form_factor.dart';
import 'package:shiyin_music/ui/pages/playlist_detail_page.dart';
import 'package:shiyin_music/ui/widgets/now_playing_badge.dart';

class _FakePlayerController extends ChangeNotifier
    implements PlayerController {
  @override
  Song? currentSong;

  @override
  bool isPlaying = false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeAuthController extends ChangeNotifier implements AuthController {
  final Set<String> likedHashes = {};

  @override
  bool isLiked(Song song) => likedHashes.contains(song.hash);

  @override
  Future<void> toggleLike(Song song) async {
    if (likedHashes.contains(song.hash)) {
      likedHashes.remove(song.hash);
    } else {
      likedHashes.add(song.hash);
    }
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUp(() {
    debugDesktopFormFactorOverride = true;
  });

  tearDown(() {
    debugDesktopFormFactorOverride = null;
  });

  Widget wrap(Widget child) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 800,
            child: child,
          ),
        ),
      ),
    );
  }

  group('DesktopSongTableHeader', () {
    testWidgets('正常模式渲染 #、歌曲标题、歌手、专辑、时长', (tester) async {
      await tester.pumpWidget(
        wrap(
          DesktopSongTableHeader(
            selecting: false,
            allSelected: false,
            onToggleSelectAll: () {},
          ),
        ),
      );

      expect(find.text('#'), findsOneWidget);
      expect(find.text('歌曲标题'), findsOneWidget);
      expect(find.text('歌手'), findsOneWidget);
      expect(find.text('专辑'), findsOneWidget);
      expect(find.text('时长'), findsOneWidget);

      final containerFinder = find.byType(Container).first;
      final size = tester.getSize(containerFinder);
      expect(size.height, 36.0);
    });

    testWidgets('多选模式在首列渲染全选勾选框且可点击', (tester) async {
      var toggled = false;
      await tester.pumpWidget(
        wrap(
          DesktopSongTableHeader(
            selecting: true,
            allSelected: false,
            onToggleSelectAll: () => toggled = true,
          ),
        ),
      );

      // 序号 # 替换为复选框
      expect(find.text('#'), findsNothing);
      expect(find.byType(DesktopSongTableHeader), findsOneWidget);

      // 点击首列 52px 区域内的全选勾选框
      final headerTopLeft = tester.getTopLeft(find.byType(DesktopSongTableHeader));
      await tester.tapAt(headerTopLeft + const Offset(26, 18));
      await tester.pumpAndSettle();
      expect(toggled, isTrue);
    });
  });

  group('DesktopSongTableRow', () {
    const testSong = Song(
      id: '101',
      title: '晴天',
      rawTitle: '周杰伦 - 晴天 [SQ]',
      artist: '周杰伦',
      hash: 'hash_qingtian_sq',
      albumName: '叶惠美',
      duration: Duration(minutes: 4, seconds: 29),
    );

    testWidgets('正常模式渲染 44px 高度与各列内容（含两位序号与 SQ 微标）', (tester) async {
      final fakePlayer = _FakePlayerController();
      final fakeAuth = _FakeAuthController();

      await tester.pumpWidget(
        wrap(
          DesktopSongTableRow(
            song: testSong,
            index: 1,
            player: fakePlayer,
            auth: fakeAuth,
            canDelete: false,
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

      final rowFinder = find.byType(DesktopSongTableRow);
      expect(tester.getSize(rowFinder).height, 44.0);

      expect(find.text('01'), findsOneWidget);
      expect(find.text('晴天'), findsOneWidget);
      expect(find.text('周杰伦'), findsOneWidget);
      expect(find.text('叶惠美'), findsOneWidget);
      expect(find.text('04:29'), findsOneWidget);
      expect(find.text('SQ'), findsOneWidget);
    });

    testWidgets('双击整行触发播放，单击整行触发选中', (tester) async {
      final fakePlayer = _FakePlayerController();
      final fakeAuth = _FakeAuthController();
      var tapCount = 0;
      var doubleTapCount = 0;

      await tester.pumpWidget(
        wrap(
          DesktopSongTableRow(
            song: testSong,
            index: 2,
            player: fakePlayer,
            auth: fakeAuth,
            canDelete: false,
            selecting: false,
            selected: false,
            isFocused: false,
            onTap: () => tapCount++,
            onDoubleTap: () => doubleTapCount++,
            onPlay: () {},
            onAddToPlaylist: () {},
            onDelete: () {},
            onViewArtist: () {},
            onMore: () {},
          ),
        ),
      );

      final rowTopLeft = tester.getTopLeft(find.byType(DesktopSongTableRow));

      // 单击歌曲标题区域触发单击选中（等待 350ms 超时）
      await tester.tapAt(rowTopLeft + const Offset(100, 22));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(tapCount, 1);

      // 双击同一区域触发直接播放
      await tester.tapAt(rowTopLeft + const Offset(100, 22));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(rowTopLeft + const Offset(100, 22));
      await tester.pumpAndSettle();
      expect(doubleTapCount, 1);
    });

    testWidgets('鼠标悬停（Hover）显示快捷操作图标并可收藏', (tester) async {
      final fakePlayer = _FakePlayerController();
      final fakeAuth = _FakeAuthController();
      var played = false;

      await tester.pumpWidget(
        wrap(
          DesktopSongTableRow(
            song: testSong,
            index: 3,
            player: fakePlayer,
            auth: fakeAuth,
            canDelete: false,
            selecting: false,
            selected: false,
            isFocused: false,
            onTap: () {},
            onDoubleTap: () {},
            onPlay: () => played = true,
            onAddToPlaylist: () {},
            onDelete: () {},
            onViewArtist: () {},
            onMore: () {},
          ),
        ),
      );

      // 未悬停时显示时长文本
      expect(find.text('04:29'), findsOneWidget);
      expect(find.byIcon(Icons.play_arrow_rounded), findsNothing);

      // 模拟鼠标悬停进入
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      await gesture.moveTo(tester.getCenter(find.byType(DesktopSongTableRow)));
      await tester.pumpAndSettle();

      // 悬停后时长切换为操作按钮组
      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
      expect(find.byIcon(Icons.favorite_border_rounded), findsOneWidget);
      expect(find.byIcon(Icons.playlist_add_rounded), findsOneWidget);
      expect(find.byIcon(Icons.more_horiz_rounded), findsOneWidget);

      // 用鼠标光标点击播放按钮
      final playCenter = tester.getCenter(find.byIcon(Icons.play_arrow_rounded));
      await gesture.moveTo(playCenter);
      await gesture.down(playCenter);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(played, isTrue);

      // 用鼠标光标点击收藏按钮
      expect(fakeAuth.isLiked(testSong), isFalse);
      final favCenter = tester.getCenter(find.byIcon(Icons.favorite_border_rounded));
      await gesture.moveTo(favCenter);
      await gesture.down(favCenter);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(fakeAuth.isLiked(testSong), isTrue);
      expect(find.byIcon(Icons.favorite_rounded), findsOneWidget);

      await gesture.removePointer();
    });

    testWidgets('当前正在播放歌曲显示高亮与 NowPlayingBadge', (tester) async {
      final fakePlayer = _FakePlayerController()
        ..currentSong = testSong
        ..isPlaying = true;
      final fakeAuth = _FakeAuthController();

      await tester.pumpWidget(
        wrap(
          DesktopSongTableRow(
            song: testSong,
            index: 1,
            player: fakePlayer,
            auth: fakeAuth,
            canDelete: false,
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

      // 正在播放时，序号列替换为 NowPlayingBadge
      expect(find.byType(NowPlayingBadge), findsOneWidget);
      expect(find.text('01'), findsNothing);
    });

    testWidgets('多选模式下序号列转为勾选框', (tester) async {
      final fakePlayer = _FakePlayerController();
      final fakeAuth = _FakeAuthController();
      var toggled = false;

      await tester.pumpWidget(
        wrap(
          DesktopSongTableRow(
            song: testSong,
            index: 1,
            player: fakePlayer,
            auth: fakeAuth,
            canDelete: false,
            selecting: true,
            selected: true,
            isFocused: false,
            onTap: () => toggled = true,
            onDoubleTap: () {},
            onPlay: () {},
            onAddToPlaylist: () {},
            onDelete: () {},
            onViewArtist: () {},
            onMore: () {},
          ),
        ),
      );

      // 序号替换为选中状态的勾选框
      expect(find.text('01'), findsNothing);
      expect(find.byIcon(Icons.check_rounded), findsOneWidget);

      // 点击整行触发勾选切换
      final rowTopLeft = tester.getTopLeft(find.byType(DesktopSongTableRow));
      await tester.tapAt(rowTopLeft + const Offset(100, 22));
      await tester.pump(const Duration(milliseconds: 350));
      expect(toggled, isTrue);
    });

    testWidgets('点击歌手调用 onViewArtist', (tester) async {
      final fakePlayer = _FakePlayerController();
      final fakeAuth = _FakeAuthController();
      var artistViewed = false;

      await tester.pumpWidget(
        wrap(
          DesktopSongTableRow(
            song: testSong,
            index: 1,
            player: fakePlayer,
            auth: fakeAuth,
            canDelete: false,
            selecting: false,
            selected: false,
            isFocused: false,
            onTap: () {},
            onDoubleTap: () {},
            onPlay: () {},
            onAddToPlaylist: () {},
            onDelete: () {},
            onViewArtist: () => artistViewed = true,
            onMore: () {},
          ),
        ),
      );

      await tester.tap(find.text('周杰伦'));
      await tester.pumpAndSettle();
      expect(artistViewed, isTrue);
    });
  });
}
