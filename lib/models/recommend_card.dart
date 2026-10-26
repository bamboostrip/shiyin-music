import 'model_parsing.dart';
import 'song.dart';

/// 首页「推荐歌曲」卡（酷狗 `/top/card`，6 个 card_id 各一组）。
///
/// 字段形态对齐上游 3.2.0（f230444）：响应根上的 `song_list` 为歌曲数组，
/// `rec_desc` 为推荐语（transport 已把 data 提升为根）；卡片本身不发封面，
/// 取组内第一首的封面作卡片封面。
class RecommendedSongCard {
  const RecommendedSongCard({
    required this.cardId,
    required this.title,
    required this.songs,
    this.description,
    this.coverUrl,
  });

  final int cardId;
  final String title;
  final String? description;
  final String? coverUrl;
  final List<Song> songs;

  /// 无描述时的兜底副标题（首页卡片与歌单页副标题共用）。
  String get songSummary {
    if (songs.isEmpty) return '推荐歌曲';
    final first = songs.first;
    return '${first.title} · ${first.artist}';
  }

  factory RecommendedSongCard.fromJson({
    required int cardId,
    required String title,
    required Map<String, dynamic> json,
  }) {
    final songs = asList(json['song_list'])
        .whereType<Map<String, dynamic>>()
        .map(Song.fromTopCard)
        .where((song) => song.hash.isNotEmpty)
        .toList();
    return RecommendedSongCard(
      cardId: cardId,
      title: title,
      description: asString(json['rec_desc']),
      coverUrl: songs.isEmpty ? null : songs.first.coverUrl,
      songs: songs,
    );
  }

  Map<String, dynamic> toCache() => {
        'cardId': cardId,
        'title': title,
        'description': description,
        'coverUrl': coverUrl,
        'songs': songs.map((song) => song.toCache()).toList(),
      };

  factory RecommendedSongCard.fromCache(Map<String, dynamic> json) {
    return RecommendedSongCard(
      cardId: asInt(json['cardId']) ?? 0,
      title: asString(json['title']) ?? '推荐歌曲',
      description: asString(json['description']),
      coverUrl: asString(json['coverUrl']),
      songs: asList(json['songs'])
          .whereType<Map<String, dynamic>>()
          .map(Song.fromCache)
          .where((song) => song.hash.isNotEmpty)
          .toList(),
    );
  }
}
