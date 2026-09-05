import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/controllers/auth_controller.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/ui/form_factor.dart';
import 'package:shiyin_music/ui/widgets/desktop_song_table_row.dart';
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

    testWidgets('空 hash 行不因「空 == 空」被误判为正在播放高亮', (tester) async {
      // 本地/占位歌曲可能没有 hash：currentSong.hash 与行 hash 均为空时
      // 不应命中高亮（否则整列表加粗高亮的假象）。
      const emptyHashSong = Song(
        id: 'local-1',
        title: '本地占位歌曲',
        artist: '未知艺人',
        duration: Duration(minutes: 3),
        hash: '',
      );
      final fakePlayer = _FakePlayerController()..currentSong = emptyHashSong;
      final fakeAuth = _FakeAuthController();

      await tester.pumpWidget(
        wrap(
          DesktopSongTableRow(
            song: emptyHashSong,
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

      // 未高亮：序号仍显示（而非 NowPlayingBadge）。
      expect(find.byType(NowPlayingBadge), findsNothing);
      expect(find.text('01'), findsOneWidget);
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

    testWidgets('右键整行触发 onSecondaryMore 并携带全局坐标', (tester) async {
      final fakePlayer = _FakePlayerController();
      final fakeAuth = _FakeAuthController();
      Offset? captured;

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
            onSecondaryMore: (position) => captured = position,
          ),
        ),
      );

      final rowTopLeft = tester.getTopLeft(find.byType(DesktopSongTableRow));
      final pressPoint = rowTopLeft + const Offset(100, 22);
      await tester.tapAt(pressPoint, buttons: kSecondaryButton);
      await tester.pumpAndSettle();

      expect(captured, isNotNull);
      expect(captured, pressPoint);
    });

    testWidgets('截断的歌名悬停显示完整提示，未截断不显示', (tester) async {
      final fakePlayer = _FakePlayerController();
      final fakeAuth = _FakeAuthController();
      final longTitle = '这是一首特别特别特别长的歌曲名称用来验证省略号截断提示' * 4;

      Widget buildRow(String title) {
        return DesktopSongTableRow(
          song: Song(
            id: '1',
            title: title,
            artist: '周杰伦',
            hash: 'hash_$title',
            albumName: '叶惠美',
            duration: const Duration(minutes: 4),
          ),
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
        );
      }

      // 长歌名：悬停后出现包含完整文本的提示层
      await tester.pumpWidget(wrap(buildRow(longTitle)));
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      await gesture.moveTo(tester.getCenter(find.text(longTitle).first));
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text(longTitle), findsNWidgets(2));

      // 移开鼠标后提示消失
      await gesture.moveTo(Offset.zero);
      await tester.pumpAndSettle();
      expect(find.text(longTitle), findsOneWidget);
      await gesture.removePointer();

      // 短歌名：悬停不出现提示层
      await tester.pumpWidget(wrap(buildRow('晴天')));
      final gesture2 =
          await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture2.addPointer(location: Offset.zero);
      await gesture2.moveTo(tester.getCenter(find.text('晴天')));
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('晴天'), findsOneWidget);
      await gesture2.removePointer();
    });

    testWidgets('用户字体缩放 1.2 时按缩放后宽度判定截断（缩放才截断的文本有提示）',
        (tester) async {
      final fakePlayer = _FakePlayerController();
      final fakeAuth = _FakeAuthController();
      // 窄容器（400px）下歌名列可用宽度约 71px：5 个字在 scale 1.0
      // （5×13.5=67.5px）恰好放得下，1.2 倍（81px）则被省略号截断。
      const title = '海阔天空传';

      Widget buildScaledRow(TextScaler scaler) {
        return MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(textScaler: scaler),
            child: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 400,
                  child: DesktopSongTableRow(
                    song: const Song(
                      id: '1',
                      title: title,
                      artist: '周杰伦',
                      hash: 'hash_scaled',
                      albumName: '叶惠美',
                      duration: Duration(minutes: 4),
                    ),
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
              ),
            ),
          ),
        );
      }

      Future<void> hoverAndCheck(TextScaler scaler, int expectedMatches) async {
        await tester.pumpWidget(buildScaledRow(scaler));
        final gesture =
            await tester.createGesture(kind: PointerDeviceKind.mouse);
        await gesture.addPointer(location: Offset.zero);
        await gesture.moveTo(tester.getCenter(find.text(title)));
        await tester.pump(const Duration(milliseconds: 600));
        expect(find.text(title), findsNWidgets(expectedMatches));
        await gesture.moveTo(Offset.zero);
        await tester.pumpAndSettle();
        await gesture.removePointer();
      }

      // 1.2 倍字体缩放：文本实际被截断 → 悬停显示完整提示
      await hoverAndCheck(TextScaler.linear(1.2), 2);
      // scale 1.0：同一文本放得下 → 不显示提示
      await hoverAndCheck(TextScaler.noScaling, 1);
    });

    testWidgets('showHoverActions=false 时悬停只显示时长（外部平台歌曲）',
        (tester) async {
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
            showHoverActions: false,
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

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      await gesture.moveTo(tester.getCenter(find.byType(DesktopSongTableRow)));
      await tester.pumpAndSettle();

      // 悬停时仍显示时长文本，操作图标全部隐藏
      expect(find.text('04:29'), findsOneWidget);
      expect(find.byIcon(Icons.play_arrow_rounded), findsNothing);
      expect(find.byIcon(Icons.favorite_border_rounded), findsNothing);
      expect(find.byIcon(Icons.playlist_add_rounded), findsNothing);
      expect(find.byIcon(Icons.more_horiz_rounded), findsNothing);
      await gesture.removePointer();
    });
  });
}
