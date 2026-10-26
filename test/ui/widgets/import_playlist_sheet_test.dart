// 导入面板（ImportPlaylistSheet）UI 流程：
// 输入 → 解析 → 选择目标歌单（新建 / 已有）→ 导入进度（可停止）→ 完成统计；
// 未登录时提示先登录且禁用写操作；解析失败保留输入；失败/未匹配清单展示。
//
// 通过 fake MusicApi + fake AuthController 驱动，不联网、不写真实歌单。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/controllers/auth_controller.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/services/music_api.dart';
import 'package:shiyin_music/ui/widgets/import_playlist_sheet.dart';

const _firstCandidate = Song(
  id: '1',
  hash: 'HASH',
  title: '同名歌曲',
  artist: '歌手甲',
  duration: Duration(seconds: 180),
);
const _secondCandidate = Song(
  id: '2',
  hash: 'HASH2',
  title: '第二首歌',
  artist: '歌手乙',
  duration: Duration(seconds: 200),
);
const _firstTrack = ExternalPlaylistTrack(
  title: '同名歌曲',
  artist: '歌手甲',
  duration: Duration(seconds: 180),
);
const _secondTrack = ExternalPlaylistTrack(
  title: '第二首歌',
  artist: '歌手乙',
  duration: Duration(seconds: 200),
);
const _parsedResult = ExternalPlaylistParseResult(
  sourcePlatform: 'QQ音乐',
  playlistName: '测试歌单',
  songNames: ['同名歌曲', '第二首歌'],
  tracks: [_firstTrack, _secondTrack],
  totalSongCount: 2,
);

class FakeImportApi implements MusicApi {
  ExternalPlaylistParseResult result = _parsedResult;
  Object? parseError;
  List<Song> candidates = const [_firstCandidate, _secondCandidate];
  List<Song> existingSongs = const [];
  bool failAdd = false;
  final added = <Song>[];
  final requestedListIds = <String>[];
  final playlistSongsIds = <String>[];
  final searchKeywords = <String>[];
  Future<List<Song>>? delayedSearch;

  @override
  Future<ExternalPlaylistParseResult> parseExternalPlaylist(
    String sourceText,
  ) async {
    final error = parseError;
    if (error != null) throw error;
    return result;
  }

  @override
  Future<List<Song>> searchSongs(
    String keywords, {
    int page = 1,
    int pageSize = 30,
  }) async {
    searchKeywords.add(keywords);
    final delayed = delayedSearch;
    if (delayed != null) return delayed;
    return candidates;
  }

  @override
  Future<Map<String, dynamic>?> addSongsToPlaylist(
    String listId,
    List<Song> songs,
  ) async {
    if (failAdd) throw StateError('write failed');
    requestedListIds.add(listId);
    added.addAll(songs);
    return null;
  }

  @override
  Future<List<Song>> playlistSongs(
    String id, {
    int page = 1,
    int pageSize = 80,
    bool fetchAll = false,
  }) async {
    playlistSongsIds.add(id);
    return existingSongs;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeAuth implements AuthController {
  FakeAuth({this.loggedIn = true, List<PlaylistSummary> playlists = const []})
    : _playlists = List.of(playlists);

  bool loggedIn;
  List<PlaylistSummary> _playlists;
  int createCalls = 0;
  int refreshes = 0;
  String? lastCreatedName;

  @override
  String? errorMessage;

  @override
  bool get isLoggedIn => loggedIn;

  @override
  List<PlaylistSummary> get playlists => _playlists;

  @override
  Future<void> createPlaylist(String name, {bool private = false}) async {
    createCalls++;
    lastCreatedName = name;
    _playlists = [
      ..._playlists,
      PlaylistSummary(
        id: 'global-new',
        title: name,
        listId: 'local-new',
        type: 0,
      ),
    ];
  }

  @override
  Future<void> refreshProfile({bool silent = false}) async {
    refreshes++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _pumpSheet(
  WidgetTester tester, {
  required FakeImportApi api,
  required FakeAuth auth,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: ImportPlaylistSheet(api: api, auth: auth)),
    ),
  );
  await tester.pump();
}

Future<void> _parse(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField).first, text);
  await tester.tap(find.text('解析歌单'));
  await tester.pumpAndSettle();
}

Future<void> _pumpUntil(
  WidgetTester tester,
  Finder finder, {
  int maxPumps = 20,
}) async {
  for (var i = 0; i < maxPumps; i++) {
    if (finder.evaluate().isNotEmpty) return;
    await tester.pump(const Duration(milliseconds: 10));
  }
  throw TestFailure('等待控件超时：$finder');
}

void main() {
  testWidgets('解析 → 新建歌单 → 导入 → 完成态展示统计', (tester) async {
    final api = FakeImportApi();
    final auth = FakeAuth();
    await _pumpSheet(tester, api: api, auth: auth);

    await _parse(tester, 'https://y.qq.com/n/ryqq/playlist/123');

    // 已解析：平台/歌单名/曲目数 + 默认选中「新建歌单」并带出名称。
    expect(find.text('2 首曲目 · QQ 音乐'), findsOneWidget);
    expect(find.text('新建歌单'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, '测试歌单');

    await tester.tap(find.text('开始导入'));
    await tester.pumpAndSettle();

    expect(auth.createCalls, 1);
    expect(auth.lastCreatedName, '测试歌单');
    expect(api.playlistSongsIds, ['global-new']);
    // 服务逐首写入（每首一次 addSongsToPlaylist），便于失败分类。
    expect(api.requestedListIds.toSet(), {'local-new'});
    expect(api.added.map((song) => song.hash), ['HASH', 'HASH2']);
    expect(auth.refreshes, 1);
    expect(find.text('导入完成'), findsOneWidget);
    expect(find.text('已处理 2/2 首'), findsOneWidget);
    expect(find.text('新增 2 · 已存在 0 · 未匹配 0 · 失败 0'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('选择已有歌单导入时跳过目标歌单已有歌曲', (tester) async {
    final api = FakeImportApi()
      ..existingSongs = const [_firstCandidate];
    final auth = FakeAuth(
      playlists: const [
        PlaylistSummary(
          id: 'global-old',
          title: '我的旧歌单',
          listId: 'local-old',
          type: 0,
        ),
      ],
    );
    await _pumpSheet(tester, api: api, auth: auth);
    await _parse(tester, 'https://y.qq.com/n/ryqq/playlist/123');

    await tester.tap(find.text('我的旧歌单'));
    await tester.pump();
    await tester.tap(find.text('开始导入'));
    await tester.pumpAndSettle();

    expect(auth.createCalls, 0);
    expect(api.playlistSongsIds, ['global-old']);
    expect(api.requestedListIds, ['local-old']);
    expect(api.added.map((song) => song.hash), ['HASH2']);
    expect(find.text('新增 1 · 已存在 1 · 未匹配 0 · 失败 0'), findsOneWidget);
  });

  testWidgets('未登录时提示先登录，且开始导入被禁用（不执行写操作）', (tester) async {
    final api = FakeImportApi();
    final auth = FakeAuth(loggedIn: false);
    await _pumpSheet(tester, api: api, auth: auth);
    await _parse(tester, 'https://y.qq.com/n/ryqq/playlist/123');

    expect(find.textContaining('尚未登录酷狗账号'), findsOneWidget);
    final button = tester.widget<FilledButton>(
      find.bySubtype<FilledButton>().first,
    );
    expect(button.onPressed, isNull);
    expect(api.added, isEmpty);
    expect(api.requestedListIds, isEmpty);
    expect(auth.createCalls, 0);
  });

  testWidgets('解析失败显示原因并保留输入内容', (tester) async {
    final api = FakeImportApi()..parseError = const FormatException('分享链接无法识别');
    final auth = FakeAuth();
    await _pumpSheet(tester, api: api, auth: auth);

    await tester.enterText(find.byType(TextField).first, '无效的分享文本');
    await tester.tap(find.text('解析歌单'));
    await tester.pumpAndSettle();

    expect(find.textContaining('解析失败：分享链接无法识别'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '无效的分享文本',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('导入完成后展示未匹配清单（可展开查看）', (tester) async {
    final api = FakeImportApi()
      ..result = const ExternalPlaylistParseResult(
        sourcePlatform: 'QQ音乐',
        playlistName: '测试歌单',
        songNames: ['同名歌曲', '找不到的歌'],
        tracks: [
          _firstTrack,
          ExternalPlaylistTrack(title: '找不到的歌', artist: '无名氏'),
        ],
        totalSongCount: 2,
      )
      ..candidates = const [_firstCandidate];
    final auth = FakeAuth();
    await _pumpSheet(tester, api: api, auth: auth);
    await _parse(tester, 'https://y.qq.com/n/ryqq/playlist/123');

    await tester.tap(find.text('开始导入'));
    await tester.pumpAndSettle();

    expect(find.text('新增 1 · 已存在 0 · 未匹配 1 · 失败 0'), findsOneWidget);
    expect(find.text('未匹配的歌曲（1）'), findsOneWidget);
    // 折叠时不渲染清单内容。
    expect(find.textContaining('无名氏 - 找不到的歌'), findsNothing);
    await tester.tap(find.text('未匹配的歌曲（1）'));
    await tester.pumpAndSettle();
    expect(find.textContaining('无名氏 - 找不到的歌'), findsOneWidget);
    expect(find.text('复制清单'), findsOneWidget);
  });

  testWidgets('导入中可停止：取消后不再新增', (tester) async {
    final search = Completer<List<Song>>();
    final api = FakeImportApi()..delayedSearch = search.future;
    final auth = FakeAuth();
    await _pumpSheet(tester, api: api, auth: auth);
    await _parse(tester, 'https://y.qq.com/n/ryqq/playlist/123');

    await tester.tap(find.text('开始导入'));
    await _pumpUntil(tester, find.text('停止导入'));
    await tester.tap(find.text('停止导入'));
    await tester.pump();
    expect(find.text('当前请求结束后停止…'), findsOneWidget);

    // 让在途搜索返回，服务在写入前检测到取消，不再新增。
    search.complete(const [_firstCandidate]);
    await tester.pumpAndSettle();
    expect(find.text('已停止导入'), findsOneWidget);
    expect(find.text('新增 0 · 已存在 0 · 未匹配 0 · 失败 0'), findsOneWidget);
    expect(api.added, isEmpty);
  });

  testWidgets('写入失败展示失败清单并可重新导入', (tester) async {
    final api = FakeImportApi()..failAdd = true;
    final auth = FakeAuth();
    await _pumpSheet(tester, api: api, auth: auth);
    await _parse(tester, 'https://y.qq.com/n/ryqq/playlist/123');

    await tester.tap(find.text('开始导入'));
    await tester.pumpAndSettle();
    expect(find.text('新增 0 · 已存在 0 · 未匹配 0 · 失败 2'), findsOneWidget);
    expect(find.text('重新导入（跳过已有歌曲）'), findsOneWidget);

    // 修复写入后重新导入：已成功的部分不会重复（本次全部失败，两首重新写入）。
    api.failAdd = false;
    await tester.tap(find.text('重新导入（跳过已有歌曲）'));
    await tester.pumpAndSettle();
    expect(api.added.map((song) => song.hash), ['HASH', 'HASH2']);
    expect(find.text('新增 2 · 已存在 0 · 未匹配 0 · 失败 0'), findsOneWidget);
  });
}
