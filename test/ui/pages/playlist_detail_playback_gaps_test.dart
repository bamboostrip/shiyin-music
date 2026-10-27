// P2-C「playlist 三个小差距」回归测试（借鉴上游 PR #156 / 10ac04d 的
// _isStartingPlayback / _playFromVisibleQueue / _showPlaybackErrorIfNeeded）：
// 1. 播放全部防连点：起播未完成时重复触发只调一次 playSong，按钮同时置灰；
// 2. 播放失败 Toast：起播结束后 player.errorMessage 非空才提示，且剥掉
//    Exception / Bad state / ApiException(状态码) / DioException 前缀；成功静默；
// 3. 单曲行点击与播放全部走同一 helper：失败同样有反馈，队列为可见列表快照；
// 4. 后台补队列判据：起播歌已切走（不在当前歌、也不在队列）时不得 replaceQueue；
// 5. M1 起播态反馈：起播挂起时粘性条播放键换成白色转圈（40px 容器内 24px），
//    不可点也不会二次起播，完成/失败后恢复播放图标；
// 6. m4 补队列时机：后台补全在 playSong 之前就触发（弱网起播挂起期间已在补）；
// 7. m1 失败提示去重：控制器 lastPlaybackFailureToast 非空（已弹友好 Toast）
//    时页面不再用 errorMessage 里的原始异常盖掉它；该字段为空才由页面兜底。
//
// 说明：不引入真实网络/音频——PlayerController 用既有 Fake 模式，
// MusicApi 用内存假实现。
import 'dart:async';

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
import 'package:shiyin_music/ui/widgets/toast.dart';

// ---------------------------------------------------------------------------
// Fake PlayerController：只实现本页用到的成员，其余走 noSuchMethod。
// ---------------------------------------------------------------------------
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

  /// 控制器最近一次失败已弹出的友好 Toast 文案；语义与真实控制器一致，
  /// 页面据此跳过重复提示，避免原始异常把友好文案盖掉。
  @override
  String? lastPlaybackFailureToast;

  @override
  final ValueNotifier<Duration> positionListenable = ValueNotifier(
    Duration.zero,
  );

  /// playSong 被调用次数（防连点断言用）。
  int playSongCalls = 0;
  Song? lastPlayedSong;
  List<Song>? lastPlayedQueue;

  /// replaceQueue 收到的队列快照（补队列判据断言用）。
  final List<List<Song>> replacedQueues = [];

  /// 非 null 时 playSong 挂起，用于构造「起播未完成」的并发窗口。
  Completer<void>? pendingPlay;

  /// 非 null 时模拟起播失败：playSong 结束前写入 errorMessage。
  String? playFailureMessage;

  /// 非 null 时模拟控制器已弹过友好失败 Toast：playSong 结束前写入
  /// [lastPlaybackFailureToast]（errorMessage 仍保留原始异常）。
  String? playFailureToast;

  @override
  Future<void> playSong(
    Song song, {
    List<Song>? queue,
    bool isRetry = false,
    Duration? initialPosition,
    bool preserveClimax = false,
    bool preservePersonalFmSession = false,
  }) async {
    playSongCalls++;
    // 与真实控制器一致：每轮起播先清空上一轮的错误与友好提示记录。
    errorMessage = null;
    lastPlaybackFailureToast = null;
    final pending = pendingPlay;
    if (pending != null) await pending.future;
    lastPlayedSong = song;
    lastPlayedQueue = queue == null ? null : List<Song>.of(queue);
    currentSong = song;
    if (queue != null && queue.isNotEmpty) {
      this.queue = List<Song>.of(queue);
    }
    errorMessage = playFailureMessage;
    lastPlaybackFailureToast = playFailureToast;
    notifyListeners();
  }

  @override
  Future<void> replaceQueue(List<Song> songs) async {
    replacedQueues.add(List<Song>.of(songs));
    queue = List<Song>.of(songs);
    notifyListeners();
  }

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

/// 静态集合（initialSongs）路径不访问 MusicApi。
class _UnusedApi implements MusicApi {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 分页歌单 API：第 1 页 50 首（hasMore=true，触发进页预加载），
/// 全量接口第 1 次（预加载）主动失败，第 2 次（点歌后补队列）挂起，
/// 由用例决定何时返回，从而构造「补全期间用户切源」的窗口。
class _PaginatedApi implements MusicApi {
  _PaginatedApi(this.allSongs);

  final List<Song> allSongs;
  int songPageCalls = 0;
  int songsPageAllCalls = 0;

  /// 非 null 时第 2 次全量请求等待它完成。
  Completer<void>? expandGate;

  @override
  Future<SongPage> playlistSongPage(
    String id, {
    int page = 1,
    int pageSize = 50,
  }) async {
    songPageCalls++;
    final start = (page - 1) * pageSize;
    final songs = allSongs.skip(start).take(pageSize).toList();
    return SongPage(songs: songs, rawItemCount: songs.length);
  }

  @override
  Future<SongPage> playlistSongsPageAll(String id) async {
    songsPageAllCalls++;
    if (songsPageAllCalls == 1) {
      // 进页后的后台静默预加载：主动失败，让补队列由点歌后的第 2 次驱动。
      throw StateError('预加载失败（测试构造）');
    }
    final gate = expandGate;
    if (gate != null) await gate.future;
    return SongPage(songs: allSongs, rawItemCount: allSongs.length);
  }

  @override
  Future<PlaylistSummary> playlistInfo(String id) async => PlaylistSummary(
    id: id,
    title: '测试歌单',
    songCount: allSongs.length,
  );

  @override
  Future<List<PlaylistSummary>> similarPlaylists(String ids) async =>
      const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// ---------------------------------------------------------------------------
// 测试辅助
// ---------------------------------------------------------------------------

List<Song> _makeSongs(int count, {String prefix = ''}) => List.generate(
  count,
  (i) => Song(
    id: '${prefix}song_$i',
    title: '$prefix歌曲 $i',
    artist: '$prefix歌手 $i',
    albumName: '专辑',
    duration: const Duration(minutes: 3),
    hash: '${prefix}hash_$i',
  ),
);

/// 播放全部按钮（粘性头里的圆形播放键）。
Finder _playAllButton() => find.descendant(
  of: find.byType(ListStickyBar),
  matching: find.byIcon(Icons.play_arrow_rounded),
);

/// 起播中的白色转圈（占据播放键位置，图标被替换）。
Finder _stickyPlaySpinner() => find.descendant(
  of: find.byType(ListStickyBar),
  matching: find.byType(CircularProgressIndicator),
);

/// 清掉错误 Toast 的静态状态与自动关闭计时器，避免跨用例串扰
/// （flutter_test 在用例结束时有未完成 Timer 会直接判失败）。
Future<void> _drainToast(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 4));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    ThemeController();
    // 统一走移动端形态：单曲行点击是 _SongRow 的单击路径。
    debugDesktopFormFactorOverride = false;
  });

  tearDown(() {
    debugDesktopFormFactorOverride = null;
  });

  /// 静态集合（initialSongs）：无分页/网络，聚焦播放交互本身。
  Future<void> pumpStaticCollection(
    WidgetTester tester, {
    required _FakePlayerController player,
    required List<Song> songs,
  }) async {
    tester.view.physicalSize = const Size(430, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: Toast.navigatorKey,
        home: Scaffold(
          body: PlaylistDetailPage(
            api: _UnusedApi(),
            auth: _FakeAuthController(),
            player: player,
            playlist: PlaylistSummary(
              id: 'pl_static',
              title: '测试集合',
              songCount: songs.length,
            ),
            initialSongs: songs,
            readOnly: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 分页歌单：50 首首屏 + 120 首全量，供补队列判据用例使用。
  Future<_PaginatedApi> pumpPaginatedPlaylist(
    WidgetTester tester, {
    required _FakePlayerController player,
  }) async {
    final api = _PaginatedApi(_makeSongs(120));
    tester.view.physicalSize = const Size(430, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: Toast.navigatorKey,
        home: Scaffold(
          body: PlaylistDetailPage(
            api: api,
            auth: _FakeAuthController(),
            player: player,
            playlist: PlaylistSummary(
              id: 'pl_page',
              title: '分页歌单',
              songCount: api.allSongs.length,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // 进页后的静默预加载已尝试（并失败），保证后面由点歌驱动第 2 次全量请求。
    expect(api.songsPageAllCalls, 1);
    return api;
  }

  /// 点播放全部后等到「后台补队列」发出第 2 次全量请求并挂起。
  Future<void> startPlayAllUntilExpansion(
    WidgetTester tester,
    _PaginatedApi api,
  ) async {
    await tester.tap(_playAllButton());
    await tester.pump();
    for (var i = 0; i < 50 && api.songsPageAllCalls < 2; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(
      api.songsPageAllCalls,
      2,
      reason: '点歌后应触发后台补全全量歌曲（第 2 次全量请求）',
    );
  }

  group('formatPlaybackError 播放失败文案', () {
    test('剥离 Exception / Bad state 前缀并保留正文', () {
      expect(formatPlaybackError('Exception: 网络连接失败'), '网络连接失败');
      expect(formatPlaybackError('Bad state: 没有可播放的音源'), '没有可播放的音源');
      expect(formatPlaybackError('Exception:   多余空格也去掉'), '多余空格也去掉');
    });

    test('无异常前缀时原样返回；前缀后为空时回退通用文案', () {
      expect(formatPlaybackError('音频地址无效'), '音频地址无效');
      // 只有前缀没有正文：给通用提示，不再把原始前缀抛给用户。
      expect(formatPlaybackError('Exception:'), '播放失败，请稍后重试');
    });

    test('剥离 ApiException(状态码) 与 DioException 前缀', () {
      // ApiException.toString() => 'ApiException($statusCode): $message'
      expect(formatPlaybackError('ApiException(500): 服务异常'), '服务异常');
      expect(formatPlaybackError('ApiException(401): 登录已过期'), '登录已过期');
      // 状态码可能为 null（本地校验失败等）。
      expect(formatPlaybackError('ApiException(null): 参数错误'), '参数错误');
      // DioException.toString() => 'DioException [type]: message'
      expect(
        formatPlaybackError('DioException [connectionError]: 网络连接失败'),
        '网络连接失败',
      );
    });

    test('多层前缀逐层剥离；剥离后无正文时回退通用文案', () {
      expect(
        formatPlaybackError('Exception: ApiException(500): 服务异常'),
        '服务异常',
      );
      expect(formatPlaybackError('ApiException(500):'), '播放失败，请稍后重试');
      expect(
        formatPlaybackError('DioException [unknown]:'),
        '播放失败，请稍后重试',
      );
    });
  });

  group('播放全部防连点', () {
    testWidgets('起播未完成时连续两次触发只起播一次，按钮同时置灰', (tester) async {
      final songs = _makeSongs(3);
      final player = _FakePlayerController();
      final gate = Completer<void>();
      player.pendingPlay = gate;
      await pumpStaticCollection(tester, player: player, songs: songs);

      // 起播挂在 playSong 里：此时第二次「播放全部」必须被防连点状态挡下。
      final bar = tester.widget<ListStickyBar>(find.byType(ListStickyBar));
      bar.onPlay();
      bar.onPlay();
      await tester.pump();

      expect(player.playSongCalls, 1);
      expect(
        tester.widget<ListStickyBar>(find.byType(ListStickyBar)).canPlay,
        isFalse,
        reason: '起播期间「播放全部」按钮应呈禁用态，给出即时反馈',
      );

      gate.complete();
      await tester.pumpAndSettle();

      expect(player.playSongCalls, 1);
      expect(
        tester.widget<ListStickyBar>(find.byType(ListStickyBar)).canPlay,
        isTrue,
        reason: '起播结束后按钮应恢复可用',
      );
      expect(player.lastPlayedQueue, hasLength(3));
    });

    testWidgets('起播期间重复点击已禁用的播放按钮不会再次起播', (tester) async {
      final player = _FakePlayerController();
      final gate = Completer<void>();
      player.pendingPlay = gate;
      await pumpStaticCollection(
        tester,
        player: player,
        songs: _makeSongs(3),
      );

      await tester.tap(_playAllButton());
      await tester.pump();
      expect(player.playSongCalls, 1);

      // 起播中播放图标已换成转圈，onTap 为 null：点同一位置也不再起播。
      expect(_stickyPlaySpinner(), findsOneWidget);
      await tester.tap(_stickyPlaySpinner(), warnIfMissed: false);
      await tester.pump();
      expect(player.playSongCalls, 1);

      gate.complete();
      await tester.pumpAndSettle();
    });
  });

  group('M1 起播态反馈', () {
    testWidgets('起播挂起时播放键变白色转圈（尺寸不跳动），完成前不会二次起播', (tester) async {
      final player = _FakePlayerController();
      final gate = Completer<void>();
      player.pendingPlay = gate;
      await pumpStaticCollection(
        tester,
        player: player,
        songs: _makeSongs(3),
      );

      await tester.tap(_playAllButton());
      await tester.pump();

      expect(player.playSongCalls, 1);
      // 播放图标换成转圈：仍在 40px 圆形按钮内、转圈本身 24px，布局不跳动。
      expect(_playAllButton(), findsNothing);
      expect(_stickyPlaySpinner(), findsOneWidget);
      final spinner = tester.widget<CircularProgressIndicator>(
        _stickyPlaySpinner(),
      );
      expect(spinner.strokeWidth, 2.4);
      expect(spinner.color, Colors.white);
      expect(tester.getSize(_stickyPlaySpinner()), const Size.square(24));
      final pill = find
          .ancestor(
            of: _stickyPlaySpinner(),
            matching: find.byType(InkWell),
          )
          .first;
      expect(tester.getSize(pill), const Size.square(40));

      final bar = tester.widget<ListStickyBar>(find.byType(ListStickyBar));
      expect(bar.starting, isTrue, reason: '起播中应把 starting 传给粘性条');
      expect(
        bar.canPlay,
        isFalse,
        reason: '起播期间「播放全部」按钮应呈禁用态，给出即时反馈',
      );
      // 二次触发（含再次命中禁用按钮）都不得再次起播。
      bar.onPlay();
      bar.onPlay();
      await tester.tap(_stickyPlaySpinner(), warnIfMissed: false);
      await tester.pump();
      expect(player.playSongCalls, 1);

      gate.complete();
      await tester.pumpAndSettle();

      expect(_stickyPlaySpinner(), findsNothing);
      expect(_playAllButton(), findsOneWidget);
      expect(
        tester.widget<ListStickyBar>(find.byType(ListStickyBar)).starting,
        isFalse,
        reason: '起播结束后应恢复播放图标',
      );
      expect(player.lastPlayedQueue, hasLength(3));
    });

    testWidgets('起播失败后转圈消失、播放图标恢复，并给出失败 Toast', (tester) async {
      final player = _FakePlayerController()
        ..playFailureMessage = 'Exception: 音频地址解析失败';
      final gate = Completer<void>();
      player.pendingPlay = gate;
      await pumpStaticCollection(
        tester,
        player: player,
        songs: _makeSongs(3),
      );

      await tester.tap(_playAllButton());
      await tester.pump();
      expect(_stickyPlaySpinner(), findsOneWidget);

      gate.complete();
      await tester.pumpAndSettle();

      expect(_stickyPlaySpinner(), findsNothing);
      expect(_playAllButton(), findsOneWidget);
      expect(find.text('播放失败：音频地址解析失败'), findsOneWidget);
      await _drainToast(tester);
    });
  });

  group('播放失败 Toast', () {
    testWidgets('起播失败时提示「播放失败：…」并剥离异常前缀', (tester) async {
      final player = _FakePlayerController()
        ..playFailureMessage = 'Exception: 音频地址解析失败';
      await pumpStaticCollection(
        tester,
        player: player,
        songs: _makeSongs(3),
      );

      await tester.tap(_playAllButton());
      await tester.pumpAndSettle();

      expect(player.playSongCalls, 1);
      expect(find.text('播放失败：音频地址解析失败'), findsOneWidget);
      await _drainToast(tester);
    });

    testWidgets('起播成功时不显示错误 Toast', (tester) async {
      final player = _FakePlayerController();
      await pumpStaticCollection(
        tester,
        player: player,
        songs: _makeSongs(3),
      );

      await tester.tap(_playAllButton());
      await tester.pumpAndSettle();

      expect(player.playSongCalls, 1);
      expect(find.textContaining('播放失败'), findsNothing);
    });

    testWidgets('单曲行点击走统一 helper：失败同样有 Toast，队列为可见列表快照', (
      tester,
    ) async {
      final songs = _makeSongs(3);
      final player = _FakePlayerController()
        ..playFailureMessage = 'Bad state: 没有可播放的音源';
      await pumpStaticCollection(tester, player: player, songs: songs);

      await tester.tap(find.text('歌曲 0'));
      await tester.pumpAndSettle();

      expect(player.playSongCalls, 1);
      expect(player.lastPlayedSong?.id, songs.first.id);
      expect(
        player.lastPlayedQueue?.map((song) => song.id),
        songs.map((song) => song.id),
        reason: '单曲点击的队列应为当前可见列表快照',
      );
      expect(find.text('播放失败：没有可播放的音源'), findsOneWidget);
      await _drainToast(tester);
    });

    testWidgets('控制器已弹《歌名》友好提示时页面不再重复弹原始异常', (tester) async {
      final player = _FakePlayerController()
        // 控制器 errorMessage 存原始异常，另用 lastPlaybackFailureToast 记录
        // 已弹过的友好文案——页面必须以后者为准去重，不能把前者盖上去。
        ..playFailureMessage = 'Exception: 音频地址解析失败'
        ..playFailureToast = '《歌曲 0》暂无可播放音源';
      await pumpStaticCollection(
        tester,
        player: player,
        songs: _makeSongs(3),
      );

      await tester.tap(_playAllButton());
      await tester.pumpAndSettle();

      expect(player.playSongCalls, 1);
      expect(
        find.textContaining('播放失败：'),
        findsNothing,
        reason: '控制器已给友好 Toast，页面不得再用原始异常盖掉',
      );
      expect(
        find.textContaining('音频地址解析失败'),
        findsNothing,
        reason: '原始异常不得出现在页面 Toast 里',
      );
      await _drainToast(tester);
    });

    testWidgets('控制器连续失败停止提示时页面不再重复弹 Toast', (tester) async {
      final player = _FakePlayerController()
        ..playFailureMessage = 'Exception: 网络连接失败'
        ..playFailureToast = '连续多首歌曲播放失败，已停止播放';
      await pumpStaticCollection(
        tester,
        player: player,
        songs: _makeSongs(3),
      );

      await tester.tap(_playAllButton());
      await tester.pumpAndSettle();

      expect(
        find.textContaining('播放失败：'),
        findsNothing,
        reason: '连续失败停止的提示由控制器统一给出，页面不叠加',
      );
      await _drainToast(tester);
    });

    testWidgets('lastPlaybackFailureToast 为空时原始异常才弹页面 Toast，并剥掉 ApiException 状态码前缀', (
      tester,
    ) async {
      final player = _FakePlayerController()
        ..playFailureMessage = 'ApiException(500): 服务异常，请稍后重试';
      // 未设置 playFailureToast：控制器没弹过友好提示（字段为 null），
      // 页面需要用格式化后的原始异常兜底。
      await pumpStaticCollection(
        tester,
        player: player,
        songs: _makeSongs(3),
      );

      await tester.tap(_playAllButton());
      await tester.pumpAndSettle();

      expect(player.lastPlaybackFailureToast, isNull);
      expect(find.text('播放失败：服务异常，请稍后重试'), findsOneWidget);
      await _drainToast(tester);
    });
  });

  group('后台补队列判据', () {
    testWidgets('起播歌已切走（不在当前歌也不在队列）时不 replaceQueue', (tester) async {
      final player = _FakePlayerController();
      final api = await pumpPaginatedPlaylist(tester, player: player);
      api.expandGate = Completer<void>();
      await startPlayAllUntilExpansion(tester, api);

      // 模拟补全期间用户切到其它来源播放：当前歌与队列都不再属于本歌单。
      final outsider = _makeSongs(1, prefix: 'other_').single;
      player.currentSong = outsider;
      player.queue = [outsider];

      api.expandGate!.complete();
      await tester.pumpAndSettle();

      expect(
        player.replacedQueues,
        isEmpty,
        reason: '起播歌已切走时，补全结果不得覆盖当前播放队列',
      );
    });

    testWidgets('起播歌仍在播时用补全结果扩展队列', (tester) async {
      final player = _FakePlayerController();
      final api = await pumpPaginatedPlaylist(tester, player: player);
      api.expandGate = Completer<void>();
      await startPlayAllUntilExpansion(tester, api);

      api.expandGate!.complete();
      await tester.pumpAndSettle();

      expect(player.replacedQueues, hasLength(1));
      expect(player.replacedQueues.single, hasLength(120));
    });

    testWidgets('补队列在 playSong 完成前已触发，完成后按全量结果替换队列', (tester) async {
      final player = _FakePlayerController();
      final playGate = Completer<void>();
      player.pendingPlay = playGate;
      final api = await pumpPaginatedPlaylist(tester, player: player);
      api.expandGate = Completer<void>();

      await tester.tap(_playAllButton());
      await tester.pump();
      // 起播仍挂起（弱网下的 40~80s 窗口）：补队列此时就该已经发出，
      // 而不是等 playSong 返回后才开始。
      for (var i = 0; i < 50 && api.songsPageAllCalls < 2; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(player.playSongCalls, 1);
      expect(
        player.currentSong,
        isNull,
        reason: 'playSong 仍挂在 pendingPlay 上，尚未完成起播',
      );
      expect(
        api.songsPageAllCalls,
        2,
        reason: '补队列应在 playSong 完成前就触发（恢复 P2 之前的立即语义）',
      );

      // 起播完成后再放行补全：结果应在起播歌仍是当前歌时替换队列。
      playGate.complete();
      await tester.pumpAndSettle();
      expect(player.currentSong?.id, api.allSongs.first.id);

      api.expandGate!.complete();
      await tester.pumpAndSettle();

      expect(player.replacedQueues, hasLength(1));
      expect(player.replacedQueues.single, hasLength(120));
    });
  });
}
