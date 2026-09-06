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

/// 网易云 / QQ 音乐歌单分享链接解析结果（/playlist/external/parse）。
class ExternalPlaylistParseResult {
  const ExternalPlaylistParseResult({
    required this.sourcePlatform,
    required this.playlistName,
    required this.songNames,
  });

  final String sourcePlatform;
  final String playlistName;
  final List<String> songNames;

  factory ExternalPlaylistParseResult.fromJson(Map<String, dynamic> json) {
    return ExternalPlaylistParseResult(
      sourcePlatform: asString(json['sourcePlatform']) ?? '',
      playlistName: asString(json['playlistName']) ?? '未命名歌单',
      songNames: asList(json['songNames'])
          .map((item) => item?.toString() ?? '')
          .where((name) => name.isNotEmpty)
          .toList(),
    );
  }
}
