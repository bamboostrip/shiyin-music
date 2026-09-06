import 'model_parsing.dart';
import 'song.dart';

class FmStation {
  const FmStation({
    required this.id,
    required this.name,
    required this.type,
    this.classId,
    this.className,
    this.description,
    this.bannerUrl,
    this.imageUrl,
    this.previewSongs = const [],
  });

  final String id;
  final String name;
  final int type;
  final String? classId;
  final String? className;
  final String? description;
  final String? bannerUrl;
  final String? imageUrl;
  final List<Song> previewSongs;

  String get subtitle {
    if (description != null && description!.isNotEmpty) {
      return description!;
    }
    if (className != null && className!.isNotEmpty) {
      return className!;
    }
    if (previewSongs.isNotEmpty) {
      return previewSongs.first.title;
    }
    return '电台';
  }

  String? get artworkUrl =>
      imageUrl ?? bannerUrl ?? previewSongs.firstOrNull?.coverUrl;

  factory FmStation.fromJson(Map<String, dynamic> json, {String? classId}) {
    final songs = asList(json['rcmdlist'] ?? json['songlist'])
        .whereType<Map>()
        .map((item) => Song.fromFm(asMap(item)))
        .where((song) => song.hash.isNotEmpty)
        .toList();
    return FmStation(
      id: asString(json['fmid']) ?? '',
      name: asString(json['fmname']) ?? '未命名电台',
      type: asInt(json['fmtype']) ?? asInt(json['type']) ?? 2,
      classId: asString(json['classid']) ?? classId,
      className: asString(json['classname']),
      description: asString(json['description']),
      bannerUrl: normalizeImageUrl(asString(json['banner'])),
      imageUrl: normalizeImageUrl(asString(json['imgurl'])),
      previewSongs: songs,
    );
  }

  FmStation mergeImage(FmImage image) {
    return FmStation(
      id: id,
      name: name,
      type: type,
      classId: classId,
      className: className,
      description: description,
      bannerUrl: image.bannerUrl ?? bannerUrl,
      imageUrl: image.imageUrl ?? imageUrl,
      previewSongs: previewSongs,
    );
  }
}

class FmClassGroup {
  const FmClassGroup({
    required this.id,
    required this.name,
    required this.stations,
  });

  final String id;
  final String name;
  final List<FmStation> stations;

  factory FmClassGroup.fromJson(Map<String, dynamic> json) {
    final id = asString(json['classid']) ?? '';
    final stations = asList(json['fmlist'])
        .whereType<Map>()
        .map((item) => FmStation.fromJson(asMap(item), classId: id))
        .where((station) => station.id.isNotEmpty)
        .toList();
    final firstClassName = stations
        .map((station) => station.className)
        .whereType<String>()
        .where((name) => name.isNotEmpty)
        .firstOrNull;

    return FmClassGroup(
      id: id,
      name: asString(json['classname']) ?? firstClassName ?? '分类 $id',
      stations: stations,
    );
  }
}

class FmSongPage {
  const FmSongPage({
    required this.fmid,
    required this.type,
    required this.offset,
    required this.size,
    required this.songs,
  });

  final String fmid;
  final int type;
  final int offset;
  final int size;
  final List<Song> songs;

  factory FmSongPage.fromJson(Map<String, dynamic> json) {
    return FmSongPage(
      fmid: asString(json['fmid']) ?? '',
      type: asInt(json['fmtype']) ?? 2,
      offset: asInt(json['offset']) ?? -1,
      size: asInt(json['size']) ?? 0,
      songs: asList(json['songs'])
          .whereType<Map>()
          .map((item) => Song.fromFm(asMap(item)))
          .where((song) => song.hash.isNotEmpty)
          .toList(),
    );
  }
}

class FmImage {
  const FmImage({
    required this.fmid,
    this.fmtype,
    this.imageUrl,
    this.bannerUrl,
  });

  final String fmid;
  final int? fmtype;
  final String? imageUrl;
  final String? bannerUrl;

  factory FmImage.fromJson(Map<String, dynamic> json) {
    return FmImage(
      fmid: asString(json['fmid']) ?? asString(json['fmId']) ?? '',
      fmtype: asInt(json['fmtype']),
      // 实测 /fm/image 返回 imgUrl100（完整 URL）；imgurl 为另一来源的旧字段名
      imageUrl: normalizeImageUrl(
        asString(json['imgUrl100']) ?? asString(json['imgurl']),
      ),
      bannerUrl: normalizeImageUrl(asString(json['banner'])),
    );
  }
}
