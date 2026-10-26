// 歌单导入服务（PlaylistImportService）：
// - match：歌名+歌手+时长匹配（复用 LocalSongIdentity），旧数据（无歌手无时长）
//   要求标题完全相等，不能取搜索结果第一条；
// - import：逐首 match → 目标歌单已有 hash（大小写不敏感）计 duplicate →
//   addSongsToPlaylist 写歌单（失败计 failed）→ 进度快照；shouldCancel 中途
//   取消后不再发起新的匹配/写入。
//
// fake MusicApi，不联网。
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/services/music_api.dart';
import 'package:shiyin_music/services/playlist_import_service.dart';

const candidate = Song(
  id: '1',
  hash: 'HASH',
  title: '同名歌曲',
  artist: '歌手甲',
  duration: Duration(seconds: 180),
);
const sourceTrack = ExternalPlaylistTrack(
  title: '同名歌曲',
  artist: '歌手甲',
  duration: Duration(seconds: 180),
);

class FakeImportApi implements MusicApi {
  List<Song> candidates = [candidate];
  final added = <Song>[];
  final requestedListIds = <String>[];
  final searchRequests = <({String keywords, int pageSize})>[];
  bool throwOnSearch = false;
  int failAddCount = 0;
  Future<List<Song>>? delayedSearch;

  @override
  Future<List<Song>> searchSongs(
    String keywords, {
    int page = 1,
    int pageSize = 30,
  }) async {
    searchRequests.add((keywords: keywords, pageSize: pageSize));
    if (throwOnSearch) throw StateError('search failed');
    final delayed = delayedSearch;
    if (delayed != null) return delayed;
    return candidates;
  }

  @override
  Future<Map<String, dynamic>?> addSongsToPlaylist(
    String listId,
    List<Song> songs,
  ) async {
    if (failAddCount > 0) {
      failAddCount--;
      throw StateError('write failed');
    }
    requestedListIds.add(listId);
    added.addAll(songs);
    return null;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('match 元数据匹配', () {
    test('歌名+歌手+时长命中时返回该歌曲，且按 20 条/页搜索', () async {
      final api = FakeImportApi();
      final song = await PlaylistImportService(api).match(sourceTrack);
      expect(song, candidate);
      expect(api.searchRequests, hasLength(1));
      expect(api.searchRequests.single.keywords, '歌手甲 同名歌曲');
      expect(api.searchRequests.single.pageSize, 20);
    });

    test('翻唱 / Live 版 / 时长差过大都不匹配', () async {
      final api = FakeImportApi()
        ..candidates = [
          const Song(
            id: 'cover',
            hash: 'COVER',
            title: '同名歌曲',
            artist: '歌手乙',
            duration: Duration(seconds: 180),
          ),
          const Song(
            id: 'live',
            hash: 'LIVE',
            title: '同名歌曲 (Live)',
            artist: '歌手甲',
            duration: Duration(seconds: 180),
          ),
          const Song(
            id: 'long',
            hash: 'LONG',
            title: '同名歌曲',
            artist: '歌手甲',
            duration: Duration(seconds: 250),
          ),
        ];
      expect(await PlaylistImportService(api).match(sourceTrack), isNull);
    });

    test('多个候选按时长差取最接近的一首', () async {
      const close = Song(
        id: 'close',
        hash: 'HASH_CLOSE',
        title: '同名歌曲',
        artist: '歌手甲',
        duration: Duration(seconds: 181),
      );
      const far = Song(
        id: 'far',
        hash: 'HASH_FAR',
        title: '同名歌曲',
        artist: '歌手甲',
        duration: Duration(seconds: 186),
      );
      final api = FakeImportApi()..candidates = [far, close];
      expect(await PlaylistImportService(api).match(sourceTrack), close);
    });

    test('旧数据（无歌手无时长）必须标题完全相等', () async {
      const other = Song(
        id: 'other',
        hash: 'OTHER',
        title: '完全不相关的歌',
        artist: '别的歌手',
      );
      final api = FakeImportApi()..candidates = [other, candidate];
      expect(
        await PlaylistImportService(
          api,
        ).match(const ExternalPlaylistTrack(title: '同名歌曲')),
        candidate,
      );
      expect(
        await PlaylistImportService(
          api,
        ).match(const ExternalPlaylistTrack(title: '找不到的歌')),
        isNull,
      );
    });

    test('空标题不发起搜索', () async {
      final api = FakeImportApi();
      expect(
        await PlaylistImportService(
          api,
        ).match(const ExternalPlaylistTrack(title: '   ')),
        isNull,
      );
      expect(api.searchRequests, isEmpty);
    });
  });

  group('import 分类与去重', () {
    test('匹配成功/未匹配/源内重复分类正确', () async {
      final api = FakeImportApi();
      final progress = await PlaylistImportService(api).import(
        listId: 'list-1',
        tracks: const [
          sourceTrack,
          ExternalPlaylistTrack(title: '找不到的歌'),
          sourceTrack,
        ],
        existingHashes: {},
        onProgress: (_) {},
        shouldCancel: () => false,
      );
      expect(progress.processed, 3);
      expect(progress.added, 1);
      expect(progress.unmatched, ['找不到的歌']);
      expect(progress.failed, isEmpty);
      expect(progress.duplicates, 1);
      expect(api.added, [candidate]);
      expect(api.requestedListIds, ['list-1']);
    });

    test('existingHashes 大小写不敏感，已存在计 duplicate', () async {
      final api = FakeImportApi();
      final progress = await PlaylistImportService(api).import(
        listId: 'list-1',
        tracks: const [sourceTrack, sourceTrack],
        existingHashes: {'hash'},
        onProgress: (_) {},
        shouldCancel: () => false,
      );
      expect(progress.added, 0);
      expect(progress.duplicates, 2);
      expect(api.added, isEmpty);
    });

    test('写入失败计 failed 且不阻断后续曲目', () async {
      final api = FakeImportApi()
        ..candidates = [
          candidate,
          const Song(
            id: '2',
            hash: 'HASH2',
            title: '第二首歌',
            artist: '歌手乙',
            duration: Duration(seconds: 200),
          ),
        ]
        ..failAddCount = 1;
      final progress = await PlaylistImportService(api).import(
        listId: 'list-1',
        tracks: const [
          sourceTrack,
          ExternalPlaylistTrack(
            title: '第二首歌',
            artist: '歌手乙',
            duration: Duration(seconds: 200),
          ),
        ],
        existingHashes: {},
        onProgress: (_) {},
        shouldCancel: () => false,
      );
      expect(progress.processed, 2);
      expect(progress.failed, ['歌手甲 - 同名歌曲']);
      expect(progress.added, 1);
      expect(api.added.map((song) => song.hash), ['HASH2']);
    });

    test('搜索异常计 failed', () async {
      final api = FakeImportApi()..throwOnSearch = true;
      final progress = await PlaylistImportService(api).import(
        listId: 'list-1',
        tracks: const [sourceTrack],
        existingHashes: {},
        onProgress: (_) {},
        shouldCancel: () => false,
      );
      expect(progress.processed, 1);
      expect(progress.failed, ['歌手甲 - 同名歌曲']);
      expect(progress.added, 0);
    });

    test('shouldCancel 在匹配返回后、写入前取消则不再新增', () async {
      final search = Completer<List<Song>>();
      final api = FakeImportApi()..delayedSearch = search.future;
      var cancelled = false;
      final run = PlaylistImportService(api).import(
        listId: 'list-1',
        tracks: const [sourceTrack],
        existingHashes: {},
        onProgress: (_) {},
        shouldCancel: () => cancelled,
      );
      // 先让 match 停在搜索请求上，再请求取消并放行结果。
      await Future<void>.delayed(Duration.zero);
      cancelled = true;
      search.complete([candidate]);
      final progress = await run;
      expect(progress.processed, 0);
      expect(progress.added, 0);
      expect(api.added, isEmpty);
    });

    test('shouldCancel 为 true 时一首都不处理', () async {
      final api = FakeImportApi();
      final progress = await PlaylistImportService(api).import(
        listId: 'list-1',
        tracks: const [sourceTrack],
        existingHashes: {},
        onProgress: (_) {},
        shouldCancel: () => true,
      );
      expect(progress.processed, 0);
      expect(api.searchRequests, isEmpty);
    });

    test('进度回调逐首触发且字段快照正确', () async {
      final api = FakeImportApi()
        ..candidates = [
          candidate,
          const Song(
            id: '2',
            hash: 'HASH2',
            title: '第二首歌',
            artist: '歌手乙',
            duration: Duration(seconds: 200),
          ),
        ];
      final snapshots = <PlaylistImportProgress>[];
      final progress = await PlaylistImportService(api).import(
        listId: 'list-1',
        tracks: const [
          sourceTrack,
          ExternalPlaylistTrack(
            title: '第二首歌',
            artist: '歌手乙',
            duration: Duration(seconds: 200),
          ),
          ExternalPlaylistTrack(title: '找不到的歌', artist: '某个歌手'),
        ],
        existingHashes: {'HASH2'},
        onProgress: snapshots.add,
        shouldCancel: () => false,
      );
      expect(snapshots, hasLength(3));
      expect(snapshots.map((item) => item.processed), [1, 2, 3]);
      expect(snapshots.map((item) => item.added), [1, 1, 1]);
      expect(snapshots.map((item) => item.duplicates), [0, 1, 1]);
      expect(snapshots.last.unmatched, ['某个歌手 - 找不到的歌']);
      expect(progress.unmatched, snapshots.last.unmatched);
    });
  });
}
