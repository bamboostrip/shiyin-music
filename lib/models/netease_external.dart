import 'model_parsing.dart';
import 'song.dart';

class NetEaseSong {
  const NetEaseSong({
    required this.id,
    required this.name,
    required this.artists,
    required this.album,
    required this.duration,
  });

  final int id;
  final String name;
  final List<NetEaseArtist> artists;
  final NetEaseAlbum album;
  final Duration duration;

  /// 转换为 [Song]，标记来源为网易云。
  Song toSong() {
    final artistName = artists.map((a) => a.name).join(' / ');
    final resolvedArtist = artistName.isNotEmpty ? artistName : '未知艺人';
    final artistRefs = artists
        .map((a) => ArtistRef(id: '${a.id}', name: a.name))
        .where((a) => a.name.isNotEmpty)
        .toList();
    final cleanedTitle = cleanSongTitle(
      name,
      artist: resolvedArtist,
      artists: artistRefs,
    );
    return Song(
      id: '$id',
      title: cleanedTitle,
      rawTitle: name,
      artist: resolvedArtist,
      hash: 'ne_$id',
      albumId: '${album.id}',
      albumAudioId: '$id',
      albumName: album.name,
      coverUrl: album.picUrl,
      duration: duration,
      artists: artistRefs,
      source: SongSource.netease,
    );
  }

  factory NetEaseSong.fromJson(Map<String, dynamic> json) {
    return NetEaseSong(
      id: asInt(json['id']) ?? 0,
      name: asString(json['name']) ?? '未知歌曲',
      artists: asList(json['ar'])
          .whereType<Map>()
          .map((item) => NetEaseArtist.fromJson(asMap(item)))
          .where((a) => a.name.isNotEmpty)
          .toList(),
      album: NetEaseAlbum.fromJson(asMap(json['al'])),
      duration: durationFromMilliseconds(json['dt']) ?? Duration.zero,
    );
  }
}

class NetEaseArtist {
  const NetEaseArtist({required this.id, required this.name});

  final int id;
  final String name;

  factory NetEaseArtist.fromJson(Map<String, dynamic> json) {
    return NetEaseArtist(
      id: asInt(json['id']) ?? 0,
      name: asString(json['name']) ?? '',
    );
  }
}

class NetEaseAlbum {
  const NetEaseAlbum({required this.id, required this.name, this.picUrl});

  final int id;
  final String name;
  final String? picUrl;

  factory NetEaseAlbum.fromJson(Map<String, dynamic> json) {
    return NetEaseAlbum(
      id: asInt(json['id']) ?? 0,
      name: asString(json['name']) ?? '未知专辑',
      picUrl: asString(json['picUrl']),
    );
  }
}

/// 外部歌单的曲目元数据。
///
/// QQ 音乐公开接口可解析出「歌名 + 歌手 + 时长」，导入时用三者一起匹配酷狗
/// 曲库，避免只按歌名搜索取第一条导致同名异版/翻唱导错。
/// 移植自上游 kgka_Music_hl 3.2.0（`dc92cfd`）。
class ExternalPlaylistTrack {
  const ExternalPlaylistTrack({
    required this.title,
    this.artist = '',
    this.duration,
  });

  final String title;
  final String artist;
  final Duration? duration;

  /// 展示名（未匹配/失败清单里用）：有歌手时 `歌手 - 歌名`。
  String get displayName => artist.isEmpty ? title : '$artist - $title';

  factory ExternalPlaylistTrack.fromJson(Map<String, dynamic> json) {
    final artistValue = json['artist'] ?? json['singer'];
    final durationMs = asInt(json['durationMs']);
    final seconds = asInt(json['duration']);
    return ExternalPlaylistTrack(
      title: asString(json['title'] ?? json['name']) ?? '',
      // 只接受字符串歌手；上游 Rust 未来若返回数组由调用方自行拼好。
      artist: artistValue is String ? artistValue.trim() : '',
      duration: durationMs != null
          ? Duration(milliseconds: durationMs)
          : seconds == null || seconds <= 0
          ? null
          : Duration(seconds: seconds),
    );
  }
}

/// 网易云 / QQ 音乐歌单分享链接解析结果（/playlist/external/parse）。
class ExternalPlaylistParseResult {
  const ExternalPlaylistParseResult({
    required this.sourcePlatform,
    required this.playlistName,
    required this.songNames,
    this.tracks = const [],
    this.totalSongCount,
  });

  final String sourcePlatform;
  final String playlistName;
  final List<String> songNames;

  /// 带歌手/时长的曲目列表（QQ 直连解析提供；旧 Rust 返回值可能为空）。
  final List<ExternalPlaylistTrack> tracks;

  /// 原歌单总曲数（QQ 接口可能返回部分不可读歌曲，用于提示差异）。
  final int? totalSongCount;

  /// 统一导入用曲目列表：优先 [tracks]；旧 Rust 返回只有 [songNames] 时回退为
  /// 纯歌名（无歌手/时长），导入时按标题完全相等匹配，避免静默导错。
  List<ExternalPlaylistTrack> get importTracks => tracks.isNotEmpty
      ? tracks
      : songNames.map((name) => ExternalPlaylistTrack(title: name)).toList();

  factory ExternalPlaylistParseResult.fromJson(Map<String, dynamic> json) {
    return ExternalPlaylistParseResult(
      sourcePlatform: asString(json['sourcePlatform']) ?? '',
      playlistName: asString(json['playlistName']) ?? '未命名歌单',
      songNames: asList(json['songNames'])
          .map((item) => item?.toString() ?? '')
          .where((name) => name.isNotEmpty)
          .toList(),
      // tracks 为可选字段：旧 Rust 返回值没有时保持空列表，不影响现有解析。
      tracks: asList(json['tracks'])
          .map((item) => ExternalPlaylistTrack.fromJson(asMap(item)))
          .where((track) => track.title.isNotEmpty)
          .toList(),
      totalSongCount: asInt(json['totalSongCount']),
    );
  }
}
