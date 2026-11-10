import 'model_parsing.dart';
import 'song.dart';

class PlaylistSummary {
  const PlaylistSummary({
    required this.id,
    required this.title,
    this.subtitle,
    this.coverUrl,
    this.songCount,
    this.playCount,
    this.isDefault,
    this.creatorName,
    this.creatorUserId,
    this.currentUserId,
    this.sourceGlobalId,
    this.sourceListId,
    this.type,
    this.source,
    this.listId,
    this.musiclibId,
  });

  final String id;
  final String title;
  final String? subtitle;
  final String? coverUrl;
  final int? songCount;
  final int? playCount;
  final int? isDefault;
  final String? creatorName;
  final String? creatorUserId;
  final String? currentUserId;
  final String? sourceGlobalId;
  final String? sourceListId;

  /// API `type` field: 0 = 用户创建, 1 = 收藏的歌单
  final int? type;

  /// API `source` field: 1 = 自建, 2 = 来自音乐库
  final int? source;

  /// Raw numeric playlist ID for track add/remove operations
  final String? listId;

  /// Album id for collected albums from `/user/playlist`
  final String? musiclibId;

  bool get isLikedPlaylist => isDefault == 2 || title.trim() == '我喜欢';

  /// 酷狗系统「默认收藏」歌单（is_def=1），不可删除，一般不展示。
  bool get isSystemDefaultCollect => isDefault == 1 || title.trim() == '默认收藏';

  /// 收藏专辑：用户歌单列表里没有 `list_create_gid` 的专辑条目。
  /// 注意：自建歌单也可能没有 `list_create_gid`，不能单靠 sourceGlobalId 为空判断。
  bool get isCollectedAlbum {
    if (isLikedPlaylist) {
      return false;
    }
    // `/user/playlist` 条目：type 0=自建/默认歌单，1=收藏歌单，都不是专辑
    if (type == 0 || type == 1) {
      return false;
    }
    if (isDefault == 0 || isDefault == 1 || isDefault == 2) {
      return false;
    }
    if (musiclibId != null && musiclibId!.isNotEmpty) {
      return sourceGlobalId == null || sourceGlobalId!.isEmpty;
    }
    // 兼容旧缓存：无 type、无 sourceGlobalId，且带 album 侧 id
    if (sourceGlobalId != null && sourceGlobalId!.isNotEmpty) {
      return false;
    }
    return sourceListId != null && sourceListId!.isNotEmpty;
  }

  String? get albumId {
    if (!isCollectedAlbum) {
      return null;
    }
    if (musiclibId?.isNotEmpty == true) {
      return musiclibId;
    }
    if (sourceListId?.isNotEmpty == true) {
      return sourceListId;
    }
    return null;
  }

  bool get isCreatedPlaylist {
    if (isLikedPlaylist || isCollectedAlbum || isSystemDefaultCollect) {
      return false;
    }
    if (type == 0) {
      return true;
    }
    if (type == 1) {
      return false;
    }
    if (currentUserId != null &&
        currentUserId!.isNotEmpty &&
        creatorUserId != null &&
        creatorUserId!.isNotEmpty) {
      return currentUserId == creatorUserId;
    }
    return false;
  }

  /// 可对歌单内歌曲做增删（自建 / 我喜欢 / 默认收藏）
  bool get canEditTracks =>
      isLikedPlaylist || isCreatedPlaylist || isSystemDefaultCollect;

  /// 可删除/取消收藏（系统默认收藏与「我喜欢」不可删）
  bool get canDeleteOrUncollect =>
      !isLikedPlaylist &&
      !isSystemDefaultCollect &&
      (isCreatedPlaylist || type == 1 || isCollectedAlbum);

  bool get hasCollectionSource {
    return (sourceGlobalId != null && sourceGlobalId!.isNotEmpty) ||
        (sourceListId != null && sourceListId!.isNotEmpty);
  }

  PlaylistSummary copyWith({
    String? id,
    String? title,
    String? subtitle,
    String? coverUrl,
    int? songCount,
    int? playCount,
    int? isDefault,
    String? creatorName,
    String? creatorUserId,
    String? currentUserId,
    String? sourceGlobalId,
    String? sourceListId,
    int? type,
    int? source,
    String? listId,
    String? musiclibId,
  }) {
    return PlaylistSummary(
      id: id ?? this.id,
      title: title ?? this.title,
      subtitle: subtitle ?? this.subtitle,
      coverUrl: coverUrl ?? this.coverUrl,
      songCount: songCount ?? this.songCount,
      playCount: playCount ?? this.playCount,
      isDefault: isDefault ?? this.isDefault,
      creatorName: creatorName ?? this.creatorName,
      creatorUserId: creatorUserId ?? this.creatorUserId,
      currentUserId: currentUserId ?? this.currentUserId,
      sourceGlobalId: sourceGlobalId ?? this.sourceGlobalId,
      sourceListId: sourceListId ?? this.sourceListId,
      type: type ?? this.type,
      source: source ?? this.source,
      listId: listId ?? this.listId,
      musiclibId: musiclibId ?? this.musiclibId,
    );
  }

  /// 用详情接口数据补全展示字段，同时保留库列表里的编辑元数据。
  PlaylistSummary mergeWithDetail(PlaylistSummary detail) {
    return copyWith(
      id: detail.id.isNotEmpty ? detail.id : null,
      title: detail.title,
      subtitle: detail.subtitle ?? subtitle,
      coverUrl: detail.coverUrl ?? coverUrl,
      songCount: detail.songCount ?? songCount,
      playCount: detail.playCount ?? playCount,
      isDefault: detail.isDefault ?? isDefault,
      creatorName: detail.creatorName ?? creatorName,
      creatorUserId: detail.creatorUserId ?? creatorUserId,
      currentUserId: detail.currentUserId ?? currentUserId,
      sourceGlobalId: detail.sourceGlobalId ?? sourceGlobalId,
      sourceListId: detail.sourceListId ?? sourceListId,
      type: detail.type ?? type,
      source: detail.source ?? source,
      listId: detail.listId ?? listId,
      musiclibId: detail.musiclibId ?? musiclibId,
    );
  }

  factory PlaylistSummary.fromRecommend(Map<String, dynamic> json) {
    final globalCollectionId = asString(json['global_collection_id']);
    final id = globalCollectionId ?? asString(json['specialid']) ?? '';
    return PlaylistSummary(
      id: id,
      title: asString(json['specialname']) ?? '未命名歌单',
      subtitle: asString(json['nickname']) ?? asString(json['intro']),
      coverUrl: normalizeImageUrl(asString(json['flexible_cover'])),
      playCount: asInt(json['play_count']),
      // 标记来源 ID，避免被 isCollectedAlbum 误判为收藏专辑，
      // 否则 PlaylistDetailPage 会走专辑加载分支导致歌曲列表为空。
      sourceGlobalId: globalCollectionId ?? id,
    );
  }

  /// 搜索歌单结果（实际入口 `/search?type=special`，字段同 api.json 的 `SearchPlaylistItem`）。
  ///
  /// 搜索接口同时下发数字 ID（`specialid`）与全局 ID（`gid`）。实测
  /// `/playlist/detail` 与 `/playlist/track/all` 只接受全局 ID：传
  /// `specialid` 会返回空响应（status=1、无歌单字段）。因此这里只取
  /// `gid`；缺失的条目无法打开详情，id 置空由服务层过滤，避免搜出
  /// 点开是空页面的死条目。
  ///
  /// `sourceGlobalId` 与 id 保持一致：搜索结果都是普通歌单而非收藏专辑。
  /// 标记来源可让 [isCollectedAlbum] / [hasCollectionSource] 按普通歌单
  /// 判定，避免详情页误走专辑（`/album/songs`）分支。
  factory PlaylistSummary.fromSearch(Map<String, dynamic> json) {
    final id = asString(json['gid']) ?? '';
    final nickname = asString(json['nickname']);
    return PlaylistSummary(
      id: id,
      title: asString(json['specialname']) ?? '未命名歌单',
      subtitle: nickname,
      coverUrl: normalizeImageUrl(asString(json['img'])),
      songCount: asInt(json['song_count']),
      playCount: asInt(json['total_play_count']),
      creatorName: nickname,
      sourceGlobalId: id.isEmpty ? null : id,
    );
  }

  factory PlaylistSummary.fromSimilar(Map<String, dynamic> json) {
    return PlaylistSummary(
      id: asString(json['global_collection_id']) ?? '',
      title: asString(json['collection_name']) ?? '未知歌单',
      coverUrl: normalizeImageUrl(
        asString(json['flexible_cover']) ?? asString(json['cover']),
      ),
      songCount: asInt(json['song_count']) ?? asInt(json['count']),
      playCount: asInt(json['heat']),
      creatorName: asString(json['user_name']),
    );
  }

  factory PlaylistSummary.fromUser(
    Map<String, dynamic> json, {
    String? currentUserId,
  }) {
    final creatorName = asString(json['list_create_username']);
    final sourceGlobalId = asString(json['list_create_gid']);
    final sourceListId = asString(json['list_create_listid']);
    return PlaylistSummary(
      id:
          sourceGlobalId ??
          asString(json['global_collection_id']) ??
          asString(json['listid']) ??
          '',
      title: asString(json['name']) ?? '我的歌单',
      subtitle: creatorName,
      coverUrl: normalizeImageUrl(asString(json['pic'])),
      songCount: asInt(json['count']),
      isDefault: asInt(json['is_def']) ?? asInt(json['is_default']),
      creatorName: creatorName,
      creatorUserId: asString(json['list_create_userid']),
      currentUserId: currentUserId,
      sourceGlobalId: sourceGlobalId,
      sourceListId: sourceListId,
      type: asInt(json['type']),
      source: asInt(json['source']),
      listId: asString(json['listid']),
      musiclibId: asString(json['musiclib_id']),
    );
  }

  factory PlaylistSummary.fromDetail(Map<String, dynamic> json) {
    return PlaylistSummary(
      id:
          asString(json['global_collection_id']) ??
          asString(json['listid']) ??
          '',
      title: asString(json['name']) ?? '歌单',
      subtitle:
          asString(json['list_create_username']) ?? asString(json['intro']),
      coverUrl: normalizeImageUrl(asString(json['pic'])),
      songCount: asInt(json['count']),
      playCount: asInt(json['heat']),
      isDefault: asInt(json['is_def']) ?? asInt(json['is_default']),
      creatorName: asString(json['list_create_username']),
      creatorUserId: asString(json['list_create_userid']),
      sourceGlobalId:
          asString(json['global_collection_id']) ??
          asString(json['list_create_gid']),
      sourceListId: asString(json['list_create_listid']),
      type: asInt(json['type']),
      source: asInt(json['source']),
      listId: asString(json['listid']),
      musiclibId: asString(json['musiclib_id']),
    );
  }

  factory PlaylistSummary.fromCache(Map<String, dynamic> json) {
    return PlaylistSummary(
      id: asString(json['id']) ?? '',
      title: asString(json['title']) ?? '我的歌单',
      subtitle: asString(json['subtitle']),
      coverUrl: asString(json['coverUrl']),
      songCount: asInt(json['songCount']),
      playCount: asInt(json['playCount']),
      isDefault: asInt(json['isDefault']),
      creatorName: asString(json['creatorName']),
      creatorUserId: asString(json['creatorUserId']),
      currentUserId: asString(json['currentUserId']),
      sourceGlobalId: asString(json['sourceGlobalId']),
      sourceListId: asString(json['sourceListId']),
      type: asInt(json['type']),
      source: asInt(json['source']),
      listId: asString(json['listId']),
      musiclibId: asString(json['musiclibId']),
    );
  }

  Map<String, dynamic> toCache() {
    return {
      'id': id,
      'title': title,
      'subtitle': subtitle,
      'coverUrl': coverUrl,
      'songCount': songCount,
      'playCount': playCount,
      'isDefault': isDefault,
      'creatorName': creatorName,
      'creatorUserId': creatorUserId,
      'currentUserId': currentUserId,
      'sourceGlobalId': sourceGlobalId,
      'sourceListId': sourceListId,
      'type': type,
      'source': source,
      'listId': listId,
      'musiclibId': musiclibId,
    };
  }
}

class PlaylistDetail {
  const PlaylistDetail({required this.info, required this.songs});

  final PlaylistSummary info;
  final List<Song> songs;
}

class SongPage {
  const SongPage({
    required this.songs,
    required this.rawItemCount,
    this.allSongs,
  });

  /// 可播放曲目（`hash` 非空）。队列/收藏/下载/多选等既有调用方只消费这部分。
  final List<Song> songs;

  /// 接口原始顺序的全部曲目（含无 `hash` 的下架/无版权曲目）。
  ///
  /// 仅供展示层使用；为 `null` 表示调用方未提供原始列表（等价于 [songs]）。
  /// 与 [songs] 共享同一批 Song 实例，不额外拷贝对象。
  final List<Song>? allSongs;

  /// 接口返回的原始条数（分页判末页与「元信息 count 对账」的口径）。
  final int rawItemCount;

  /// 原始顺序的全部曲目；旧构造路径没有 [allSongs] 时回退 [songs]。
  List<Song> get orderedSongs => allSongs ?? songs;

  /// 无 hash（下架/无版权）曲目数量。
  int get unavailableCount =>
      rawItemCount > songs.length ? rawItemCount - songs.length : 0;
}

/// 歌手简介的分段（`/artist/detail` 的 long_intro 数组）。
///
/// 上游 e55e8db：long_intro 是 `[{title, content}]`，title 可能是「简介」
/// 「基本信息」这类小标题，content 才是正文。
class ArtistIntroSection {
  const ArtistIntroSection({required this.title, required this.content});

  final String title;
  final String content;

  factory ArtistIntroSection.fromJson(Map<String, dynamic> json) {
    return ArtistIntroSection(
      title: asString(json['title']) ?? '',
      content: asString(json['content']) ?? '',
    );
  }
}

class ArtistDetail {
  const ArtistDetail({
    required this.id,
    required this.name,
    this.avatarUrl,
    this.birthday,
    this.intro,
    this.introSections = const [],
  });

  final String id;
  final String name;
  final String? avatarUrl;
  final String? birthday;

  /// 简介短文本（`intro` 字段）。
  final String? intro;

  /// 简介分段（`long_intro` 字段），通常比 [intro] 完整。
  final List<ArtistIntroSection> introSections;

  /// 完整简介：优先用 long_intro 分段拼接，缺失时退回 intro。
  String get introText {
    final fromSections = introSections
        .map((section) => [
          if (section.title.isNotEmpty) section.title,
          if (section.content.isNotEmpty) section.content,
        ].join('\n'))
        .where((text) => text.isNotEmpty)
        .join('\n\n');
    if (fromSections.isNotEmpty) return fromSections;
    return intro?.trim() ?? '';
  }

  factory ArtistDetail.fromJson(
    Map<String, dynamic> json, {
    required String id,
  }) {
    return ArtistDetail(
      id: id,
      name: asString(json['author_name']) ?? '未知歌手',
      avatarUrl: normalizeImageUrl(
        asString(json['sizable_avatar']) ?? asString(json['avatar']),
      ),
      birthday: asString(json['birthday']),
      intro: asString(json['intro']),
      introSections: asList(json['long_intro'])
          .whereType<Map<String, dynamic>>()
          .map(ArtistIntroSection.fromJson)
          .toList(),
    );
  }
}

class DailyRecommend {
  const DailyRecommend({
    required this.title,
    this.subtitle,
    this.coverUrl,
    required this.songs,
  });

  final String title;
  final String? subtitle;
  final String? coverUrl;
  final List<Song> songs;

  factory DailyRecommend.fromJson(Map<String, dynamic> json) {
    final date = asString(json['creation_date']);
    return DailyRecommend(
      title: date == null ? '每日推荐' : '每日推荐 $date',
      subtitle: asString(json['sub_title']),
      coverUrl: normalizeImageUrl(asString(json['cover_img_url'])),
      songs: asList(json['song_list'])
          .whereType<Map<String, dynamic>>()
          .map(Song.fromDaily)
          .where((song) => song.hash.isNotEmpty)
          .toList(),
    );
  }

  Map<String, dynamic> toCache() => {
    'title': title,
    'subtitle': subtitle,
    'coverUrl': coverUrl,
    'songs': songs.map((s) => s.toCache()).toList(),
  };

  factory DailyRecommend.fromCache(Map<String, dynamic> json) {
    return DailyRecommend(
      title: asString(json['title']) ?? '每日推荐',
      subtitle: asString(json['subtitle']),
      coverUrl: asString(json['coverUrl']),
      songs: asList(json['songs'])
          .whereType<Map<String, dynamic>>()
          .map(Song.fromCache)
          .where((song) => song.hash.isNotEmpty)
          .toList(),
    );
  }
}

/// 歌手专辑（/artist/albums）。
class ArtistAlbum {
  const ArtistAlbum({
    required this.id,
    required this.name,
    this.coverUrl,
    this.authorName,
    this.publishDate,
    this.intro,
    this.language,
  });

  final String id;
  final String name;
  final String? coverUrl;
  final String? authorName;
  final String? publishDate;
  final String? intro;

  /// 语种（如 `国语` / `英语`，album_detail 的 language 字段）。
  final String? language;

  factory ArtistAlbum.fromJson(Map<String, dynamic> json) {
    return ArtistAlbum(
      id: asString(json['album_id']) ?? asString(json['id']) ?? '',
      name: asString(json['album_name']) ?? asString(json['name']) ?? '未知专辑',
      coverUrl: normalizeImageUrl(
        // 上游 cover 字段只返回文件名（如 20260319xxx.jpg），不是可加载的
        // URL；sizable_cover 才是完整地址，必须优先。
        asString(json['sizable_cover']) ?? asString(json['cover']),
      ),
      authorName: asString(json['author_name']),
      publishDate: asString(json['publish_date']),
      intro: asString(json['intro']),
      language: asString(json['language']),
    );
  }
}
