import '../models/music_models.dart';
import 'local_song_matcher.dart';
import 'music_api.dart';

/// 一次导入的进度快照（不可变，供 UI 直接 setState）。
class PlaylistImportProgress {
  const PlaylistImportProgress({
    this.processed = 0,
    this.added = 0,
    this.duplicates = 0,
    this.unmatched = const [],
    this.failed = const [],
  });

  /// 已处理曲目数（含未匹配/失败/重复，不含被取消跳过的）。
  final int processed;

  /// 已成功写入目标歌单的曲目数。
  final int added;

  /// 目标歌单已存在而跳过的曲目数。
  final int duplicates;

  /// 未匹配到酷狗歌曲的展示名列表。
  final List<String> unmatched;

  /// 匹配/写入失败的展示名列表（可重新导入）。
  final List<String> failed;
}

/// 把外部歌单（QQ 公开接口 / 网易云 Rust 解析）导入到酷狗自建歌单。
///
/// 移植自上游 kgka_Music_hl 3.2.0（`dc92cfd`），复用 fork 的
/// [LocalSongIdentity] 匹配规则（标题严格相等 + 歌手/时长校验，宁缺毋滥）。
class PlaylistImportService {
  PlaylistImportService(this._api);

  final MusicApi _api;

  /// 单曲搜索匹配：歌名 + 歌手 + 时长一起匹配，取时长差最小的候选。
  Future<Song?> match(ExternalPlaylistTrack track) async {
    final title = track.title.trim();
    if (title.isEmpty) return null;
    final identity = LocalSongIdentity(
      title,
      track.artist,
      track.duration,
    );
    final songs = await _api
        .searchSongs(identity.query, pageSize: 20)
        .timeout(const Duration(seconds: 20));
    if (track.artist.isNotEmpty || track.duration != null) {
      final candidates = identity.matchCandidates(songs);
      return candidates.isEmpty ? null : candidates.first;
    }
    // 旧解析结果（如网易云 Rust 路径）只有歌名：必须标题完全相等，
    // 不能退化成「搜索结果第一条」，否则同名异版会被静默导错。
    final target = title.toLowerCase();
    for (final song in songs) {
      if (song.source == SongSource.kugou &&
          song.hash.isNotEmpty &&
          song.title.trim().toLowerCase() == target) {
        return song;
      }
    }
    return null;
  }

  /// 逐首匹配并写入目标歌单，返回最终进度快照。
  ///
  /// - [existingHashes]：目标歌单已有歌曲 hash（大小写不敏感），用于去重；
  /// - [onProgress]：每处理一首回调一次进度快照；
  /// - [shouldCancel]：每首开始前与匹配完成后检查，取消后不再发起新的匹配/写入。
  ///
  /// 写操作（[MusicApi.addSongsToPlaylist]）刻意不加超时：超时会让写入结果
  /// 未知，重试可能重复添加；停止请求在该次写入完成后才生效。
  Future<PlaylistImportProgress> import({
    required String listId,
    required List<ExternalPlaylistTrack> tracks,
    required Set<String> existingHashes,
    required void Function(PlaylistImportProgress) onProgress,
    required bool Function() shouldCancel,
  }) async {
    final hashes = existingHashes.map((hash) => hash.toLowerCase()).toSet();
    final unmatched = <String>[];
    final failed = <String>[];
    var processed = 0;
    var added = 0;
    var duplicates = 0;
    PlaylistImportProgress snapshot() => PlaylistImportProgress(
      processed: processed,
      added: added,
      duplicates: duplicates,
      unmatched: List.unmodifiable(unmatched),
      failed: List.unmodifiable(failed),
    );
    for (final track in tracks) {
      if (shouldCancel()) break;
      try {
        final song = await match(track);
        if (shouldCancel()) break;
        if (song == null) {
          unmatched.add(track.displayName);
        } else if (hashes.contains(song.hash.toLowerCase())) {
          duplicates++;
        } else {
          await _api.addSongsToPlaylist(listId, [song]);
          hashes.add(song.hash.toLowerCase());
          added++;
        }
      } catch (_) {
        failed.add(track.displayName);
      }
      processed++;
      onProgress(snapshot());
    }
    return snapshot();
  }
}
