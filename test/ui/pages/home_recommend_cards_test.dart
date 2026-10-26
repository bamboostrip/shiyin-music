// 首页「推荐歌曲」横轨（/top/card，上游 f230444）与 HomeData 缓存 roundtrip：
// - 有数据时展示「推荐歌曲」标题与卡片文案；空列表不渲染（不占位）。
// - encodeCache/decodeCache 必须带上 recommendedSongCards（缓存 key 同名），
//   且只保留 cardId>0 且有歌的卡片。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/controllers/auth_controller.dart';
import 'package:shiyin_music/controllers/download_controller.dart';
import 'package:shiyin_music/controllers/local_music_controller.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/controllers/theme_controller.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/services/cache_service.dart';
import 'package:shiyin_music/services/music_api.dart';
import 'package:shiyin_music/ui/form_factor.dart';
import 'package:shiyin_music/ui/pages/home_page.dart';

class _FakeMusicApi implements MusicApi {
  List<RecommendedSongCard> recommendedCards = const [];

  @override
  Future<DailyRecommend> dailyRecommend() async {
    return DailyRecommend(title: '每日推荐', songs: [_song(1), _song(2)]);
  }

  @override
  Future<List<PlaylistSummary>> recommendedPlaylists({
    int categoryId = 0,
    int page = 1,
  }) async => const [];

  @override
  Future<List<Song>> topSongs({int type = 21608, int page = 1}) async =>
      const [];

  @override
  Future<List<RecommendedSongCard>> recommendedSongCards() async =>
      recommendedCards;

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
  bool autoPlayOnStartupEnabled = false;

  @override
  bool hasRestoredPlaybackState = false;

  @override
  final ValueNotifier<Duration> positionListenable =
      ValueNotifier(Duration.zero);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeAuthController extends ChangeNotifier implements AuthController {
  @override
  bool isRestoring = false;

  @override
  bool get isLoggedIn => true;

  @override
  bool isLiked(Song song) => false;

  @override
  Future<void> toggleLike(Song song) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeCache implements CacheService {
  @override
  Future<CacheResult<T>?> read<T>(
    String key, {
    required T Function(Map<String, dynamic> json) decode,
    Duration ttl = const Duration(hours: 24),
  }) async {
    return null;
  }

  @override
  Future<void> write(String key, Map<String, dynamic> payload) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeDownloadController extends ChangeNotifier
    implements DownloadController {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeLocalMusicController extends ChangeNotifier
    implements LocalMusicController {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Song _song(int i) => Song(
      id: 'id_$i',
      title: '歌曲$i',
      artist: '歌手$i',
      hash: 'hash_$i',
    );

RecommendedSongCard _card(int cardId, String title, {String? description}) {
  return RecommendedSongCard(
    cardId: cardId,
    title: title,
    description: description,
    coverUrl: null,
    songs: [_song(cardId)],
  );
}

void main() {
  // _RecommendHeader / ThemeController.instance 读取车机开关，默认 false。
  ThemeController();

  Future<(_FakeMusicApi, HomePageState)> pumpHome(
    WidgetTester tester, {
    required List<RecommendedSongCard> cards,
  }) async {
    debugDesktopFormFactorOverride = false;
    addTearDown(() => debugDesktopFormFactorOverride = null);
    tester.view.physicalSize = const Size(800, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final api = _FakeMusicApi()..recommendedCards = cards;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HomePage(
            api: api,
            auth: _FakeAuthController(),
            player: _FakePlayerController(),
            cache: _FakeCache(),
            theme: ThemeController(),
            downloads: _FakeDownloadController(),
            localMusic: _FakeLocalMusicController(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (api, tester.state<HomePageState>(find.byType(HomePage)));
  }

  testWidgets('有推荐卡片时展示「推荐歌曲」横轨与卡片文案', (tester) async {
    await pumpHome(
      tester,
      cards: [
        _card(1, '私人专属好歌', description: '根据你的口味精选'),
        _card(2, '经典怀旧金曲'),
      ],
    );

    expect(find.text('推荐歌曲'), findsOneWidget);
    expect(find.text('私人专属好歌'), findsOneWidget);
    // 有 rec_desc 用描述；无描述回退首曲 songSummary。
    expect(find.text('根据你的口味精选'), findsOneWidget);
    expect(find.text('歌曲2 · 歌手2'), findsOneWidget);
  });

  testWidgets('推荐卡片为空时不渲染该横轨', (tester) async {
    await pumpHome(tester, cards: const []);

    expect(find.text('推荐歌曲'), findsNothing);
  });

  testWidgets('HomeData 缓存 roundtrip：recommendedSongCards 写入并还原', (tester) async {
    final (_, state) = await pumpHome(tester, cards: const []);

    final data = HomeData(
      daily: const DailyRecommend(title: '每日推荐', songs: []),
      playlists: const [],
      recommendedSongCards: [
        RecommendedSongCard(
          cardId: 3,
          title: '热门好歌精选',
          description: '热门推荐语',
          coverUrl: 'http://img.kugou.com/480/c.jpg',
          songs: [
            Song(
              id: 'mix_3',
              title: '热门歌曲',
              artist: '热门歌手',
              hash: 'HASH_3',
              albumAudioId: 'mix_3',
              coverUrl: 'http://img.kugou.com/480/c.jpg',
              duration: const Duration(milliseconds: 259160),
            ),
          ],
        ),
      ],
    );

    final encoded = state.encodeCache(data);
    expect(encoded['recommendedSongCards'], isA<List<dynamic>>());
    expect((encoded['recommendedSongCards'] as List<dynamic>).length, 1);

    final decoded = state.decodeCache(encoded);
    expect(decoded.recommendedSongCards, hasLength(1));
    final card = decoded.recommendedSongCards.single;
    expect(card.cardId, 3);
    expect(card.title, '热门好歌精选');
    expect(card.description, '热门推荐语');
    expect(card.coverUrl, 'http://img.kugou.com/480/c.jpg');
    expect(card.songs.single.hash, 'HASH_3');
    expect(
      card.songs.single.duration,
      const Duration(milliseconds: 259160),
    );
    // 只有推荐卡片时也算有内容，避免被当成接口异常的空数据丢弃。
    expect(state.hasContent(decoded), isTrue);
  });
}
