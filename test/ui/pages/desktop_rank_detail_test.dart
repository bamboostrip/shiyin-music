import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyin_music/controllers/auth_controller.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/controllers/theme_controller.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/services/music_api.dart';
import 'package:shiyin_music/ui/form_factor.dart';
import 'package:shiyin_music/ui/widgets/desktop_song_table_row.dart';
import 'package:shiyin_music/ui/pages/rank_page.dart';

class _FakeMusicApi implements MusicApi {
  List<Song> songsToReturn = const [];

  @override
  Future<RankSongPage> rankAudio({
    required int rankId,
    int rankCid = 0,
    int page = 1,
    int pageSize = 30,
  }) async {
    return RankSongPage(songs: songsToReturn, total: songsToReturn.length);
  }

  @override
  Future<List<Song>> rankAudioAll({
    required int rankId,
    int rankCid = 0,
    int pageSize = 50,
    int maxPages = 20,
  }) async {
    return songsToReturn;
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
  const testRank = RankCategory(
    rankId: 666,
    rankName: '酷狗飙升榜',
    imageUrl: null,
    updateFrequency: '每天更新',
  );

  const testSong1 = Song(
    id: '1',
    title: '海阔天空',
    artist: 'Beyond',
    albumName: '华纳唱片',
    duration: Duration(seconds: 324),
    hash: 'hash_beyond',
  );

  const testSong2 = Song(
    id: '2',
    title: '光辉岁月',
    artist: 'Beyond',
    albumName: '命运派对',
    duration: Duration(seconds: 302),
    hash: 'hash_guanghui',
  );

  late _FakeMusicApi api;
  late _FakePlayerController player;
  late _FakeAuthController auth;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ThemeController();
    api = _FakeMusicApi()..songsToReturn = [testSong1, testSong2];
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
          body: RankDetailPage(
            api: api,
            auth: auth,
            player: player,
            rank: testRank,
          ),
        ),
      ),
    );
  }

  group('RankDetailPage PC 桌面端适配 (isDesktopFormFactor == true)', () {
    setUp(() {
      debugDesktopFormFactorOverride = true;
    });

    testWidgets('渲染桌面端紧凑横排头部与更新周期歌曲统计', (tester) async {
      await tester.pumpWidget(buildSubject());
      await tester.pumpAndSettle();

      // 排行榜标题与统计信息
      expect(find.text('酷狗飙升榜'), findsWidgets);
      expect(find.text('2 首歌曲 · 每天更新'), findsOneWidget);
      expect(find.text('播放全部'), findsOneWidget);

      // 表格表头存在
      expect(find.byType(DesktopSongTableHeader), findsOneWidget);
      expect(find.text('#'), findsOneWidget);
      expect(find.text('歌曲标题'), findsOneWidget);
      expect(find.text('歌手'), findsOneWidget);
      expect(find.text('专辑'), findsOneWidget);
      expect(find.text('时长'), findsOneWidget);

      // 表格数据行
      expect(find.byType(DesktopSongTableRow), findsNWidgets(2));
      expect(find.text('海阔天空'), findsOneWidget);
      expect(find.text('华纳唱片'), findsOneWidget);
      expect(find.text('光辉岁月'), findsOneWidget);
      expect(find.text('命运派对'), findsOneWidget);
    });

    testWidgets('双击整行直接播放歌曲，单击设置聚焦', (tester) async {
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

    testWidgets('点击头部【播放全部】播放第一首并传递完整队列', (tester) async {
      await tester.pumpWidget(buildSubject());
      await tester.pumpAndSettle();

      final playAllBtn = find.widgetWithText(FilledButton, '播放全部');
      expect(playAllBtn, findsOneWidget);

      await tester.tap(playAllBtn);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(player.lastPlayedSong?.hash, testSong1.hash);
      expect(player.lastQueue?.length, 2);
    });
  });

  group('RankDetailPage 移动端保持原有布局 (isDesktopFormFactor == false)', () {
    setUp(() {
      debugDesktopFormFactorOverride = false;
    });

    testWidgets('非桌面端不渲染 DesktopSongTableHeader 与 DesktopSongTableRow', (tester) async {
      await tester.pumpWidget(buildSubject());
      await tester.pumpAndSettle();

      // 桌面端表格组件不应存在
      expect(find.byType(DesktopSongTableHeader), findsNothing);
      expect(find.byType(DesktopSongTableRow), findsNothing);

      // 移动端卡片列表及歌曲内容应正常渲染
      expect(find.text('海阔天空'), findsOneWidget);
      expect(find.text('光辉岁月'), findsOneWidget);
      expect(find.text('2 首歌曲'), findsOneWidget);
    });
  });
}
