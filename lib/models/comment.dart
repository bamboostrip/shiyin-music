import 'model_parsing.dart';

class CommentLikeInfo {
  const CommentLikeInfo({this.count, this.haslike, this.likenum});

  final int? count;
  final bool? haslike;
  final int? likenum;

  factory CommentLikeInfo.fromJson(Map<String, dynamic> json) {
    return CommentLikeInfo(
      count: asInt(json['count']),
      haslike: json['haslike'] is bool ? json['haslike'] : null,
      likenum: asInt(json['likenum']),
    );
  }
}

class CommentVipInfo {
  const CommentVipInfo({this.vipType, this.mType, this.userType});

  final int? vipType;
  final int? mType;
  final int? userType;

  factory CommentVipInfo.fromJson(Map<String, dynamic> json) {
    return CommentVipInfo(
      vipType: asInt(json['vip_type']),
      mType: asInt(json['m_type']),
      userType: asInt(json['user_type']),
    );
  }
}

class CommentImage {
  const CommentImage({this.url, this.width, this.height});

  final String? url;
  final int? width;
  final int? height;

  factory CommentImage.fromJson(Map<String, dynamic> json) {
    return CommentImage(
      url: normalizeImageUrl(asString(json['url'])),
      width: asInt(json['width']),
      height: asInt(json['height']),
    );
  }
}

class CommentUserDetail {
  const CommentUserDetail({
    this.medalType,
    this.medalRollWord,
    this.wordV3,
    this.pendantName,
    this.pendantUrl,
  });

  final String? medalType;
  final String? medalRollWord;
  final String? wordV3;
  final String? pendantName;
  final String? pendantUrl;

  factory CommentUserDetail.fromJson(Map<String, dynamic> json) {
    return CommentUserDetail(
      medalType: asString(json['medal_type']),
      medalRollWord: asString(json['medal_roll_word']),
      wordV3: asString(json['word_v3']),
      pendantName: asString(json['pendant_name']),
      pendantUrl: normalizeImageUrl(asString(json['pendant_url'])),
    );
  }
}

class CommentTailInfo {
  const CommentTailInfo({this.id, this.name});

  final String? id;
  final String? name;

  factory CommentTailInfo.fromJson(Map<String, dynamic> json) {
    return CommentTailInfo(
      id: asString(json['id']),
      name: asString(json['name']),
    );
  }
}

class CommentHotWord {
  const CommentHotWord({this.content, this.count});

  final String? content;
  final int? count;

  factory CommentHotWord.fromJson(Map<String, dynamic> json) {
    return CommentHotWord(
      content: asString(json['content']),
      count: asInt(json['count']),
    );
  }
}

class CommentClassifyItem {
  const CommentClassifyItem({this.id, this.label, this.icon, this.cnt});

  final int? id;
  final String? label;
  final String? icon;
  final int? cnt;

  factory CommentClassifyItem.fromJson(Map<String, dynamic> json) {
    return CommentClassifyItem(
      id: asInt(json['id']),
      label: asString(json['label']),
      icon: asString(json['icon']),
      cnt: asInt(json['cnt']),
    );
  }
}

class CommentTag {
  const CommentTag({this.name, this.type, this.count});

  final String? name;
  final String? type;
  final int? count;

  factory CommentTag.fromJson(Map<String, dynamic> json) {
    return CommentTag(
      name: asString(json['name']),
      type: asString(json['type']),
      count: asInt(json['count']),
    );
  }
}

class CommentConfig {
  const CommentConfig({this.emptyTip, this.inputHint});

  final String? emptyTip;
  final String? inputHint;

  factory CommentConfig.fromJson(Map<String, dynamic> json) {
    return CommentConfig(
      emptyTip: asString(json['emptyTip']),
      inputHint: asString(json['input_hint']),
    );
  }
}

class CommentSongScore {
  const CommentSongScore({this.scoreUserCount, this.songScore});

  final int? scoreUserCount;
  final double? songScore;

  factory CommentSongScore.fromJson(Map<String, dynamic> json) {
    return CommentSongScore(
      scoreUserCount: asInt(json['score_user_count']),
      songScore: (json['song_score'] is num)
          ? (json['song_score'] as num).toDouble()
          : double.tryParse(asString(json['song_score']) ?? ''),
    );
  }
}

class MusicCommentItem {
  const MusicCommentItem({
    required this.id,
    this.content,
    this.addtime,
    this.replyNum,
    this.userId,
    this.userName,
    this.userPic,
    this.userSex,
    this.like,
    this.images,
    this.location,
    this.hash,
    this.score,
    this.vipinfo,
    this.udetail,
    this.machineTail,
    this.tail,
  });

  final int id;
  final String? content;
  final String? addtime;
  final int? replyNum;
  final int? userId;
  final String? userName;
  final String? userPic;
  final int? userSex;
  final CommentLikeInfo? like;
  final List<CommentImage>? images;
  final String? location;
  final String? hash;
  final int? score;
  final CommentVipInfo? vipinfo;
  final CommentUserDetail? udetail;
  final String? machineTail;
  final CommentTailInfo? tail;

  factory MusicCommentItem.fromJson(Map<String, dynamic> json) {
    return MusicCommentItem(
      id: asInt(json['id']) ?? 0,
      content: asString(json['content']),
      addtime: asString(json['addtime']),
      replyNum: asInt(json['reply_num']),
      userId: asInt(json['user_id']),
      userName: asString(json['user_name']),
      userPic: normalizeImageUrl(asString(json['user_pic'])),
      userSex: asInt(json['user_sex']),
      like: json['like'] is Map
          ? CommentLikeInfo.fromJson(asMap(json['like']))
          : null,
      images: json['images'] is List
          ? asList(json['images'])
                .whereType<Map>()
                .map((e) => CommentImage.fromJson(asMap(e)))
                .toList()
          : null,
      location: asString(json['location']),
      hash: asString(json['hash']),
      score: asInt(json['score']),
      vipinfo: json['vipinfo'] is Map
          ? CommentVipInfo.fromJson(asMap(json['vipinfo']))
          : null,
      udetail: json['udetail'] is Map
          ? CommentUserDetail.fromJson(asMap(json['udetail']))
          : null,
      machineTail: asString(json['machine_tail']),
      tail: json['tail'] is Map
          ? CommentTailInfo.fromJson(asMap(json['tail']))
          : null,
    );
  }
}

class MusicCommentResponse {
  const MusicCommentResponse({
    this.msg,
    this.message,
    this.childrenid,
    this.count,
    this.combineCount,
    this.currentPage,
    this.maxPage,
    this.list,
    this.hotWordList,
    this.classifyList,
    this.tag,
    this.config,
    this.songScore,
    this.status,
    this.errorCode,
  });

  final String? msg;
  final String? message;
  final String? childrenid;
  final int? count;
  final int? combineCount;
  final int? currentPage;
  final int? maxPage;
  final List<MusicCommentItem>? list;
  final List<CommentHotWord>? hotWordList;
  final List<CommentClassifyItem>? classifyList;
  final List<CommentTag>? tag;
  final CommentConfig? config;
  final CommentSongScore? songScore;
  final int? status;
  final int? errorCode;

  factory MusicCommentResponse.fromJson(Map<String, dynamic> json) {
    return MusicCommentResponse(
      msg: asString(json['msg']),
      message: asString(json['message']),
      childrenid: asString(json['childrenid']),
      count: asInt(json['count']),
      combineCount: asInt(json['combine_count']),
      currentPage: asInt(json['current_page']),
      maxPage: asInt(json['maxPage']),
      list: json['list'] is List
          ? asList(json['list'])
                .whereType<Map>()
                .map((e) => MusicCommentItem.fromJson(asMap(e)))
                .toList()
          : null,
      hotWordList: json['hot_word_list'] is List
          ? asList(json['hot_word_list'])
                .whereType<Map>()
                .map((e) => CommentHotWord.fromJson(asMap(e)))
                .toList()
          : null,
      classifyList: json['classify_list'] is List
          ? asList(json['classify_list'])
                .whereType<Map>()
                .map((e) => CommentClassifyItem.fromJson(asMap(e)))
                .toList()
          : null,
      tag: json['tag'] is List
          ? asList(json['tag'])
                .whereType<Map>()
                .map((e) => CommentTag.fromJson(asMap(e)))
                .toList()
          : null,
      config: json['config'] is Map
          ? CommentConfig.fromJson(asMap(json['config']))
          : null,
      songScore: json['song_score'] is Map
          ? CommentSongScore.fromJson(asMap(json['song_score']))
          : null,
      status: asInt(json['status']),
      errorCode: asInt(json['error_code']),
    );
  }
}
