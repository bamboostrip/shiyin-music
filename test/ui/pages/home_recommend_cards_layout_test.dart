// 首页「推荐歌曲」PC / 车机布局回归：
// - 桌面宽窗（内容宽 ≥840）转懒构建网格，封面撑满列宽、与「推荐歌单」同列宽
//   （此前复用通用横轨网格：格子按 2×itemWidth 放宽、封面固定 120，
//   4+2 排布且卡片间大片留白，见 issue 截图）。
// - 手机窄内容区维持原横轨（封面 120、单行横向滚动）零回归。
// - 车机 Column 宿主改为一行预览网格（封面撑满列宽），与「推荐歌单」车机网格
//   同口径（此前同样掉进通用网格的大留白）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
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
import 'package:shiyin_music/ui/widgets/artwork.dart';

class _FakeMusicApi implements MusicApi {
  @override
  Future<DailyRecommend> dailyRecommend() async => DailyRecommend(
        title: '每日推荐',
        songs: List.generate(2, (i) => _song(i)),
      );

  @override
  Future<List<PlaylistSummary>> recommendedPlaylists({
    int categoryId = 0,
    int page = 1,
  }) async =>
      List.generate(
        6,
        (i) => PlaylistSummary(
          id: 'pl_$i',
          title: '歌单$i',
          subtitle: '${100 + i}万',
        ),
      );

  @override
  Future<List<Song>> topSongs({int type = 21608, int page = 1}) async =>
      const [];

  @override
  Future<List<RecommendedSongCard>> recommendedSongCards() async => [
        _card(1, '私人专属好歌', '根据你的口味精选'),
        _card(2, '经典怀旧金曲', '经典怀旧好歌推荐'),
        _card(3, '热门好歌精选', '热门好歌一网打尽'),
        _card(4, '小众宝藏佳作', '小众宝藏等你发现'),
        _card(5, '潮流尝鲜', '潮流新歌抢先听'),
        _card(6, 'VIP 专属推荐', 'VIP歌曲专属推荐'),
      ];

  @override
  Future<List<RankCategory>> rankList({int withSong = 0}) async => const [];

  @override
  Future<List<Song>> newSongs({int rankId = 0, int page = 1}) async =>
      const [];

  @override
  Future<List<FmStation>> fmRecommendedStations() async => const [];

  @override
  Future<List<FmClassGroup>> fmClassGroups() async => const [];

  @override
  Future<Map<String, FmImage>> fmImages(List<String> fmids) async => const {};

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Song _song(int i) => Song(
      id: 'id_$i',
      title: '歌曲$i',
      artist: '歌手$i',
      hash: 'hash_$i',
    );

RecommendedSongCard _card(int cardId, String title, String desc) =>
    RecommendedSongCard(
      cardId: cardId,
      title: title,
      description: desc,
      songs: [_song(cardId)],
    );

class _FakePlayerController extends ChangeNotifier implements PlayerController {
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
  int get likedCount => 0;
  @override
  List<PlaylistSummary> get createdPlaylists => const [];
  @override
  List<PlaylistSummary> get collectedPlaylists => const [];
  @override
  List<PlaylistSummary> get collectedAlbums => const [];
  @override
  PlaylistSummary? get likedPlaylist => null;
  @override
  UserProfile? get profile => null;
  @override
  UserVipInfo? get vipInfo => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeCache implements CacheService {
  @override
  Future<CacheResult<T>?> read<T>(
    String key, {
    required T Function(Map<String, dynamic> json) decode,
    Duration ttl = const Duration(hours: 24),
  }) async =>
      null;
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

const _cardTitles = <String>[
  '私人专属好歌',
  '经典怀旧金曲',
  '热门好歌精选',
  '小众宝藏佳作',
  '潮流尝鲜',
  'VIP 专属推荐',
];

/// 一张推荐卡片的封面矩形（封面在卡片 InkWell 内唯一）。
Rect _coverRect(WidgetTester tester, String cardTitle) {
  final title = find.text(cardTitle);
  expect(title, findsOneWidget, reason: '推荐卡片 $cardTitle 应该被渲染');
  final tile = find.ancestor(of: title, matching: find.byType(InkWell)).first;
  final cover = find.descendant(of: tile, matching: find.byType(Artwork));
  return tester.getRect(cover);
}

/// 按封面顶边分组 → 每行卡片数（网格换行证据）。
List<int> _rowSizes(WidgetTester tester) {
  final rows = <String, int>{};
  for (final title in _cardTitles) {
    final top = _coverRect(tester, title).top.toStringAsFixed(1);
    rows[top] = (rows[top] ?? 0) + 1;
  }
  final tops = rows.keys.map(double.parse).toList()..sort();
  return [for (final t in tops) rows[t.toStringAsFixed(1)]!];
}

/// 卡片最多的一行里，相邻两张封面的横向步进（封面左边缘间距）。
double _pitch(WidgetTester tester) {
  final byTop = <String, List<double>>{};
  for (final title in _cardTitles) {
    final rect = _coverRect(tester, title);
    byTop.putIfAbsent(rect.top.toStringAsFixed(1), () => []).add(rect.left);
  }
  final row = byTop.values.reduce((a, b) => a.length >= b.length ? a : b)
    ..sort();
  expect(row.length, greaterThanOrEqualTo(2));
  return row[1] - row[0];
}

/// 推荐歌单网格的横向步进（参照列宽）。
double _playlistPitch(WidgetTester tester) {
  Rect playlistCover(String title) {
    final t = find.text(title);
    expect(t, findsOneWidget, reason: '推荐歌单 $title 应该被渲染');
    final tile = find.ancestor(of: t, matching: find.byType(InkWell)).first;
    return tester.getRect(
      find.descendant(of: tile, matching: find.byType(Artwork)),
    );
  }

  final lefts = [playlistCover('歌单0').left, playlistCover('歌单1').left]
    ..sort();
  return lefts[1] - lefts[0];
}

Future<void> _pumpHome(
  WidgetTester tester, {
  required Size size,
  required bool desktop,
  bool carMode = false,
}) async {
  SharedPreferences.setMockInitialValues({});
  debugDesktopFormFactorOverride = desktop;
  addTearDown(() => debugDesktopFormFactorOverride = null);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final theme = ThemeController();
  if (carMode) {
    await theme.setCarModeEnabled(true);
    addTearDown(() async {
      await ThemeController.instance.setCarModeEnabled(false);
    });
  }

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: HomePage(
          api: _FakeMusicApi(),
          auth: _FakeAuthController(),
          player: _FakePlayerController(),
          cache: _FakeCache(),
          theme: theme,
          downloads: _FakeDownloadController(),
          localMusic: _FakeLocalMusicController(),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _scrollToSection(WidgetTester tester) async {
  final scroller = find.byType(CustomScrollView).first;
  await tester.dragUntilVisible(
    find.text('推荐歌曲'),
    scroller,
    const Offset(0, -200),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('桌面宽窗 1055：推荐歌曲为一行网格，封面撑满列宽、与推荐歌单同列距',
      (tester) async {
    await _pumpHome(
      tester,
      // 1055 为用户 1266 宽窗口减去左侧导航栏后的内容宽（截图同口径）；
      // 视口加高让下方「推荐歌单」网格一并进入构建范围。
      size: const Size(1055, 1500),
      desktop: true,
    );
    await _scrollToSection(tester);

    // 6 张卡全部落在同一行（修复前为 4+2 两行）。
    expect(_rowSizes(tester), [6]);

    // 横向步进 = 格宽 + 14 列距 ≈ 172；修复前 = 格宽(252+12) ≈ 258。
    final songPitch = _pitch(tester);
    expect(songPitch, greaterThan(160));
    expect(songPitch, lessThan(190));

    // 封面撑满格宽（封面宽 = 步进 - 14 列距；修复前固定 120）。
    final cover = _coverRect(tester, '私人专属好歌');
    expect(cover.width, greaterThan(140));
    expect(cover.width, closeTo(songPitch - 14, 0.5));

    // 与下方「推荐歌单」网格严格同列：步进一致（同为 160 列宽 + 14 列距）。
    expect(_playlistPitch(tester), closeTo(songPitch, 0.5));
    expect(tester.takeException(), isNull);
  });

  testWidgets('手机窄内容区 400：推荐歌曲保持横轨，封面 120 不变',
      (tester) async {
    await _pumpHome(
      tester,
      size: const Size(400, 900),
      desktop: false,
    );
    await _scrollToSection(tester);

    // 横轨形态：单行横向滚动，封面仍为 120；首屏只懒构建可见的卡片，
    // 因此只断言前两张（修复前口径）。
    final first = _coverRect(tester, '私人专属好歌');
    final second = _coverRect(tester, '经典怀旧金曲');
    expect(first.width, 120.0);
    expect(second.width, 120.0);
    expect(first.top, second.top);
    // 横向步进 = 120 + 12 间距。
    expect(second.left - first.left, closeTo(132.0, 0.5));
    expect(tester.takeException(), isNull);
  });

  testWidgets('车机内容宽 892：推荐歌曲为一行预览网格，封面撑满列宽（修复 4+2 大留白）',
      (tester) async {
    await _pumpHome(
      tester,
      // 1273 宽车机窗口减去 380 左侧播放面板 + 1 分割线后的内容宽（截图同口径）。
      size: const Size(892, 860),
      desktop: false,
      carMode: true,
    );
    await _scrollToSection(tester);

    // 内容宽 892 按 180 上限放 5 列：6 张为 5+1（修复前为 4+2 且卡片间
    // 大留白，与「推荐歌单」车机网格不一致）。
    final rows = _rowSizes(tester);
    expect(rows.length, 2);
    expect(rows.first, 5);
    expect(rows.last, 1);

    // 封面撑满格宽（修复前固定 120）；格宽 ≈ 160，与「推荐歌单」车机封面
    //（~158）同档。
    final coverPitch = _pitch(tester);
    final cover = _coverRect(tester, '私人专属好歌');
    expect(cover.width, greaterThan(140));
    expect(cover.width, closeTo(coverPitch - 14, 0.5));
    expect(coverPitch, greaterThan(160));
    expect(coverPitch, lessThan(190));
    expect(tester.takeException(), isNull);
  });

  testWidgets('内容宽 839/840 边界：839 保持横轨、840 转网格', (tester) async {
    // 839（<840）：与修复前一致的横轨——封面 120、步进 132、单行排布。
    await _pumpHome(
      tester,
      size: const Size(839, 1500),
      desktop: true,
    );
    await _scrollToSection(tester);
    expect(_rowSizes(tester), [6]);
    final railFirst = _coverRect(tester, '私人专属好歌');
    final railSecond = _coverRect(tester, '经典怀旧金曲');
    expect(railFirst.width, 120.0);
    expect(railSecond.left - railFirst.left, closeTo(132.0, 0.5));
    expect(tester.takeException(), isNull);

    // 840（= 网格起点）：转网格 → 5 列，6 张为 5+1，封面撑满格宽。
    await _pumpHome(
      tester,
      size: const Size(840, 1500),
      desktop: true,
    );
    await _scrollToSection(tester);
    final gridRows = _rowSizes(tester);
    expect(gridRows.length, 2);
    expect(gridRows.first, 5);
    final gridPitch = _pitch(tester);
    expect(
      _coverRect(tester, '私人专属好歌').width,
      closeTo(gridPitch - 14, 0.5),
    );
    expect(tester.takeException(), isNull);
  });
}
