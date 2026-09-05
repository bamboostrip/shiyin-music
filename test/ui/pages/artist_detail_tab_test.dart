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
import 'package:shiyin_music/ui/widgets/album_grid.dart';
import 'package:shiyin_music/ui/widgets/desktop_song_table_row.dart';

class _FakeMusicApi implements MusicApi {
  ArtistDetail? detailToReturn;
  List<Song> Function(int page)? songsForPage;
  List<Song> songsToReturn = const [];
  List<ArtistAlbum> albumsToReturn = const [];

  int audiosCallCount = 0;

  @override
  Future<ArtistDetail> artistDetail(String artistId) async {
    return detailToReturn ??
        ArtistDetail(
          id: artistId,
          name: '周杰伦',
          avatarUrl: 'https://example.com/jay.jpg',
        );
  }

  @override
  Future<List<Song>> artistAudios(
    String artistId, {
    int page = 1,
    int pageSize = 30,
    String sort = 'hot',
  }) async {
    audiosCallCount++;
    if (songsForPage != null) {
      return songsForPage!(page);
    }
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

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeAuthController extends ChangeNotifier implements AuthController {
  @override
  bool isLiked(Song song) => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  const testArtist = ArtistRef(
    id: '3520',
    name: '周杰伦',
    avatarUrl: 'https://example.com/jay.jpg',
  );

  const testAlbum1 = ArtistAlbum(
    id: '201',
    name: '范特西',
    coverUrl: 'https://example.com/fantasy.jpg',
    publishDate: '2001-09-14',
  );

  const testAlbum2 = ArtistAlbum(
    id: '202',
    name: '八度空间',
    coverUrl: 'https://example.com/badukongjian.jpg',
    publishDate: '2002-07-18',
  );

  List<Song> generateSongs(int count, {int startIndex = 0}) {
    return List.generate(
      count,
      (i) => Song(
        id: '${startIndex + i + 1}',
        title: '歌曲 ${startIndex + i + 1}',
        artist: '周杰伦',
        albumName: '叶惠美',
        duration: const Duration(minutes: 4),
        hash: 'hash_${startIndex + i + 1}',
      ),
    );
  }

  late _FakeMusicApi api;
  late _FakePlayerController player;
  late _FakeAuthController auth;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ThemeController();
    api = _FakeMusicApi()
      ..songsToReturn = generateSongs(5)
      ..albumsToReturn = [testAlbum1, testAlbum2];
    player = _FakePlayerController();
    auth = _FakeAuthController();
    debugDesktopFormFactorOverride = true;
  });

  tearDown(() {
    debugDesktopFormFactorOverride = null;
  });

  Widget buildSubject() {
    return MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(size: Size(1600, 1000)),
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

  void useDesktopSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  group('ArtistDetailPage Tab 结构重构与预加载', () {
    testWidgets(
      'Test 1: 默认显示【精选单曲】Tab，直接展示歌曲表格且不被专辑区块下压',
      (tester) async {
        useDesktopSurface(tester);
        await tester.pumpWidget(buildSubject());
        await tester.pumpAndSettle();

        // 验证 Tab 栏存在
        expect(find.text('精选单曲'), findsOneWidget);
        expect(find.text('所有专辑'), findsOneWidget);

        // 验证默认显示单曲，专辑网格未显示
        expect(find.byType(DesktopSongTableRow), findsNWidgets(5));
        expect(find.text('歌曲 1'), findsOneWidget);
        expect(find.byType(AlbumSliverGridSection), findsNothing);
        expect(find.text('范特西'), findsNothing);
      },
    );

    testWidgets(
      'Test 2: 点击【所有专辑】Tab 切换视图展示专辑网格，点击【精选单曲】切回歌曲列表',
      (tester) async {
        useDesktopSurface(tester);
        await tester.pumpWidget(buildSubject());
        await tester.pumpAndSettle();

        // 点击【所有专辑】Tab
        await tester.tap(find.text('所有专辑'));
        await tester.pumpAndSettle();

        // 验证展示专辑网格，隐藏单曲表格
        expect(find.byType(AlbumSliverGridSection), findsOneWidget);
        expect(find.text('范特西'), findsOneWidget);
        expect(find.text('八度空间'), findsOneWidget);
        expect(find.byType(DesktopSongTableRow), findsNothing);

        // 点击切回【精选单曲】Tab
        await tester.tap(find.text('精选单曲'));
        await tester.pumpAndSettle();

        // 验证切回歌曲表格，隐藏专辑网格
        expect(find.byType(DesktopSongTableRow), findsNWidgets(5));
        expect(find.byType(AlbumSliverGridSection), findsNothing);
      },
    );

    testWidgets(
      'Test 3: 渐进式预加载：第1页加载完成后后台静默加载后续页，动态歌曲计数及 Tab 计数更新',
      (tester) async {
        useDesktopSurface(tester);

        // 模拟第 1 页 30 首歌 (满页 hasMore = true)，第 2 页 10 首歌 (hasMore = false)
        api.songsForPage = (page) {
          if (page == 1) {
            return generateSongs(30, startIndex: 0);
          } else if (page == 2) {
            return generateSongs(10, startIndex: 30);
          }
          return const [];
        };

        await tester.pumpWidget(buildSubject());
        // pump 初始加载第 1 页完成
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        // 第 1 页完成后：hasMore 为 true，显示“已加载 30 首热门单曲”
        expect(find.text('已加载 30 首热门单曲 · 2 张专辑'), findsOneWidget);
        expect(find.text('30'), findsOneWidget); // Tab 上的歌曲计数 badge

        // 前进时间触发渐进式预加载 (250ms 后请求第 2 页)
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();

        // 渐进式加载完成：全部 40 首加载完毕，hasMore 变为 false，显示“共 40 首热门单曲”
        expect(find.text('共 40 首热门单曲 · 2 张专辑'), findsOneWidget);
        expect(find.text('40'), findsOneWidget); // Tab 上的歌曲计数 badge 更新为 40
        expect(api.audiosCallCount, greaterThanOrEqualTo(2));
      },
    );
  });
}
