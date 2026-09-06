import 'model_parsing.dart';
import 'song.dart';

class SearchHotKeyword {
  const SearchHotKeyword({required this.keyword, this.reason});

  final String keyword;
  final String? reason;

  factory SearchHotKeyword.fromJson(Map<String, dynamic> json) {
    return SearchHotKeyword(
      keyword: asString(json['keyword']) ?? '',
      reason: asString(json['reason']),
    );
  }
}

class SearchHotCategory {
  const SearchHotCategory({required this.name, required this.keywords});

  final String name;
  final List<SearchHotKeyword> keywords;

  factory SearchHotCategory.fromJson(Map<String, dynamic> json) {
    return SearchHotCategory(
      name: asString(json['name']) ?? '',
      keywords: asList(json['keywords'])
          .whereType<Map<String, dynamic>>()
          .map(SearchHotKeyword.fromJson)
          .toList(),
    );
  }
}

class SearchArtistResult {
  const SearchArtistResult({
    required this.id,
    required this.name,
    this.avatarUrl,
    this.songCount = 0,
  });

  final String id;
  final String name;
  final String? avatarUrl;
  final int songCount;

  factory SearchArtistResult.fromJson(Map<String, dynamic> json) {
    return SearchArtistResult(
      id:
          asString(json['singerid']) ??
          asString(json['singer_id']) ??
          asString(json['author_id']) ??
          asString(json['id']) ??
          '',
      name:
          asString(json['singername']) ??
          asString(json['singer_name']) ??
          asString(json['author_name']) ??
          asString(json['name']) ??
          '未知歌手',
      avatarUrl: normalizeImageUrl(
        asString(json['sizable_avatar']) ??
            asString(json['avatar']) ??
            asString(json['img']),
      ),
      songCount: asInt(json['songcount'] ?? json['song_count']) ?? 0,
    );
  }
}

class SearchAlbumResult {
  const SearchAlbumResult({
    required this.albumId,
    required this.albumName,
    this.artistName = '',
    this.coverUrl,
    this.songCount = 0,
  });

  final String albumId;
  final String albumName;
  final String artistName;
  final String? coverUrl;
  final int songCount;

  factory SearchAlbumResult.fromJson(Map<String, dynamic> json) {
    return SearchAlbumResult(
      albumId:
          asString(json['albumid']) ??
          asString(json['album_id']) ??
          asString(json['id']) ??
          '',
      albumName:
          asString(json['albumname']) ??
          asString(json['album_name']) ??
          asString(json['name']) ??
          '未知专辑',
      artistName:
          asString(json['singername']) ??
          asString(json['author_name']) ??
          asString(json['singer_name']) ??
          '',
      coverUrl: normalizeImageUrl(
        asString(json['sizable_cover']) ??
            asString(json['cover']) ??
            asString(json['img']),
      ),
      songCount: asInt(json['songcount'] ?? json['song_count']) ?? 0,
    );
  }
}

// ---------------------------------------------------------------------------
// 排行榜 (Rank)
// ---------------------------------------------------------------------------

class RankCategory {
  const RankCategory({
    required this.rankId,
    required this.rankName,
    this.rankType = 0,
    this.imageUrl,
    this.children = const [],
    this.songs = const [],
    this.updateFrequency = '',
  });

  final int rankId;
  final String rankName;
  final int rankType;
  final String? imageUrl;
  final List<RankCategory> children;
  final List<Song> songs;
  final String updateFrequency;

  factory RankCategory.fromJson(Map<String, dynamic> json) {
    final children = asList(
      json['children'],
    ).whereType<Map<String, dynamic>>().map(RankCategory.fromJson).toList();
    final songs = asList(json['songlist'])
        .whereType<Map<String, dynamic>>()
        .map(Song.fromRank)
        .where((s) => s.hash.isNotEmpty)
        .toList();
    return RankCategory(
      rankId: asInt(json['rankid']) ?? 0,
      rankName: asString(json['rankname']) ?? '未知榜单',
      rankType: asInt(json['ranktype']) ?? 0,
      imageUrl: normalizeImageUrl(asString(json['imgurl'])),
      children: children,
      songs: songs,
      updateFrequency:
          asString(json['update_frequency']) ??
          asString(json['frequency']) ??
          asString(json['period']) ??
          '',
    );
  }
}

class RankSongPage {
  const RankSongPage({required this.songs, this.total = 0});

  final List<Song> songs;
  final int total;
}
