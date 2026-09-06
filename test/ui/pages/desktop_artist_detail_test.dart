import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyin_music/controllers/auth_controller.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/controllers/theme_controller.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/services/music_api.dart';
import 'package:shiyin_music/ui/form_factor.dart';
import 'package:shiyin_music/ui/pages/artist_detail_page.dart';
import 'package:shiyin_music/ui/widgets/desktop_song_table_row.dart';
import 'package:shiyin_music/ui/widgets/album_grid.dart';
import 'package:shiyin_music/ui/widgets/horizontal_wheel_scroll.dart';
import 'package:shiyin_music/ui/widgets/mini_player.dart';

class _FakeMusicApi implements MusicApi {
  ArtistDetail? detailToReturn;
  List<Song> songsToReturn = const [];
  List<ArtistAlbum> albumsToReturn = const [];

  @override
  Future<ArtistDetail> artistDetail(String artistId) async {
    return detailToReturn ??
        ArtistDetail(
          id: artistId,
          name: '周杰伦',
          avatarUrl: 'https://example.com/jay.jpg',
          birthday: '1979-01-18',
        );
  }

  @override
  Future<List<Song>> artistAudios(
    String artistId, {
    int page = 1,
    int pageSize = 30,
    String sort = 'hot',
  }) async {
    return songsToReturn;
  }

  @override
  Future<List<ArtistAlbum>> artistAlbums(
    String artistId, {
    int page = 1,
    int pageSize = 20,
  }) async {
    return albumsToReturn;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakePlayerController extends ChangeNotifier
    implements PlayerController {
  @override
  Song? currentSong;

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
  List<Song> queue = [];

  @override
  final ValueNotifier<Duration> positionListenable =
      ValueNotifier(Duration.zero);

  Song? lastPlayedSong;
  List<Song>? lastQueue;

  @override
  Future<void> playSong(
    Song song, {
    List<Song>? queue,
    bool isRetry = false,
    Duration? initialPosition,
    bool preserveClimax = false,
  }) async {
    lastPlayedSong = song;
    lastQueue = queue;
    this.queue = queue ?? [song];
    currentSong = song;
    isPlaying = true;
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeAuthController extends ChangeNotifier implements AuthController {
  final Set<String> likedHashes = {};

  @override
  bool isLiked(Song song) => likedHashes.contains(song.hash);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  const testArtist = ArtistRef(
    id: '3520',
    name: '周杰伦',
    avatarUrl: 'https://example.com/jay.jpg',
  );

  const testSong1 = Song(
    id: '101',
    title: '晴天',
    artist: '周杰伦',
    albumName: '叶惠美',
    duration: Duration(minutes: 4, seconds: 29),
    hash: 'hash_qingtian',
  );

  const testSong2 = Song(
    id: '102',
    title: '七里香',
    artist: '周杰伦',
    albumName: '七里香',
    duration: Duration(minutes: 4, seconds: 59),
    hash: 'hash_qilixiang',
  );

  const testAlbum = ArtistAlbum(
    id: '201',
    name: '范特西',
    coverUrl: 'https://example.com/fantasy.jpg',
    publishDate: '2001-09-14',
  );

  late _FakeMusicApi api;
  late _FakePlayerController player;
  late _FakeAuthController auth;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ThemeController();
    api = _FakeMusicApi()
      ..songsToReturn = [testSong1, testSong2]
      ..albumsToReturn = [testAlbum];
    player = _FakePlayerController();
    auth = _FakeAuthController();
  });

  tearDown(() {
    debugDesktopFormFactorOverride = null;
  });

  Widget buildSubject() {
    return MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(size: Size(1200, 800)),
        child: Scaffold(
          body: ArtistDetailPage(
            api: api,
            auth: auth,
            player: player,
            artist: testArtist,
          ),
        ),
      ),
    );
  }

  /// PC 用例使用更大的测试表面：默认 800x600 下，专辑网格比旧横向轨道
  /// 更高，第二行歌曲行会落在视口外（SliverFixedExtentList 不构建
  /// 视口外条目），需要完整看到 2 行表格行。
  void useDesktopSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  group('ArtistDetailPage PC 桌面端适配 (isDesktopFormFactor == true)', () {
    setUp(() {
      debugDesktopFormFactorOverride = true;
    });

    testWidgets('渲染桌面端紧凑横排头部与统计信息及【播放热门单曲】按钮', (tester) async {
      useDesktopSurface(tester);
      await tester.pumpWidget(buildSubject());
      await tester.pumpAndSettle();

      // 歌手名与统计信息
      expect(find.text('周杰伦'), findsWidgets);
      expect(find.text('共 2 首热门单曲 · 1 张专辑'), findsOneWidget);
      expect(find.text('播放热门单曲'), findsOneWidget);

      // 表格表头存在
      expect(find.byType(DesktopSongTableHeader), findsOneWidget);
      expect(find.text('#'), findsOneWidget);
      expect(find.text('歌曲标题'), findsOneWidget);
      expect(find.text('歌手'), findsWidgets);
      expect(find.text('专辑'), findsWidgets);
      expect(find.text('时长'), findsOneWidget);

      // 表格数据行
      expect(find.byType(DesktopSongTableRow), findsNWidgets(2));
      expect(find.text('晴天'), findsOneWidget);
      expect(find.text('叶惠美'), findsOneWidget);
      expect(find.text('七里香'), findsWidgets);

      // 切换到【所有专辑】Tab，专辑区为 PC 响应式网格（不再使用横向滚轮轨道）
      await tester.tap(find.text('所有专辑'));
      await tester.pumpAndSettle();
      expect(find.text('专辑 1'), findsOneWidget);
      expect(find.text('范特西'), findsOneWidget);
      expect(find.byType(AlbumSliverGridSection), findsOneWidget);
      expect(find.byType(HorizontalWheelScroll), findsNothing);
    });

    testWidgets('双击表格行直接播放歌曲，单击设置聚焦', (tester) async {
      useDesktopSurface(tester);
      await tester.pumpWidget(buildSubject());
      await tester.pumpAndSettle();

      final firstRow = find.byType(DesktopSongTableRow).first;

      // 单击聚焦
      await tester.tap(firstRow);
      await tester.pump();

      // 双击播放
      await tester.tap(firstRow);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(firstRow);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(player.lastPlayedSong?.hash, testSong1.hash);
      expect(player.lastQueue?.length, 2);
    });

    testWidgets('点击头部【播放热门单曲】播放第一首并传递完整队列', (tester) async {
      useDesktopSurface(tester);
      await tester.pumpWidget(buildSubject());
      await tester.pumpAndSettle();

      final playAllBtn = find.widgetWithText(FilledButton, '播放热门单曲');
      expect(playAllBtn, findsOneWidget);

      await tester.tap(playAllBtn);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(player.lastPlayedSong?.hash, testSong1.hash);
      expect(player.lastQueue?.length, 2);
    });

    testWidgets('桌面端不渲染独立悬浮 MiniPlayer', (tester) async {
      useDesktopSurface(tester);
      player.currentSong = testSong1;
      player.isPlaying = true;

      await tester.pumpWidget(buildSubject());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byType(MiniPlayer), findsNothing);
    });
  });

  group('ArtistDetailPage 移动端/车机端保持原有布局 (isDesktopFormFactor == false)', () {
    setUp(() {
      debugDesktopFormFactorOverride = false;
    });

    testWidgets('非桌面端不渲染 DesktopSongTableHeader 与 DesktopSongTableRow', (tester) async {
      tester.view.physicalSize = const Size(1200, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(buildSubject());
      await tester.pumpAndSettle();

      // 桌面端表格组件不应存在
      expect(find.byType(DesktopSongTableHeader), findsNothing);
      expect(find.byType(DesktopSongTableRow), findsNothing);

      // 移动端卡片列表及歌曲内容应正常渲染
      expect(find.text('晴天'), findsOneWidget);
      expect(find.text('七里香'), findsWidgets);
      expect(find.text('热门歌曲 2'), findsOneWidget);
      // 移动端包含标题栏右侧的 TextButton 播放按钮
      expect(find.widgetWithText(TextButton, '播放'), findsOneWidget);
    });

    testWidgets('移动端播放中渲染 MiniPlayer', (tester) async {
      player.currentSong = testSong1;
      player.isPlaying = true;

      await tester.pumpWidget(buildSubject());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byType(MiniPlayer), findsOneWidget);
    });

    testWidgets('移动端点击【所有专辑】Tab 渲染 AlbumSliverGridSection 竖向网格', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(buildSubject());
      await tester.pumpAndSettle();

      await tester.tap(find.text('所有专辑'));
      await tester.pumpAndSettle();

      expect(find.byType(AlbumSliverGridSection), findsOneWidget);
      expect(find.text('范特西'), findsOneWidget);
      expect(find.text('专辑 1'), findsOneWidget);
    });

    testWidgets('移动端歌手头部不使用 28px 圆角裁切', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(buildSubject());
      await tester.pumpAndSettle();

      final clipRRects = tester.widgetList<ClipRRect>(find.byType(ClipRRect));
      for (final clip in clipRRects) {
        if (clip.borderRadius is BorderRadius) {
          final br = clip.borderRadius as BorderRadius;
          expect(br.bottomLeft.x, isNot(28.0));
          expect(br.bottomRight.x, isNot(28.0));
        }
      }
    });
  });
}
