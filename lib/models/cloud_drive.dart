import 'model_parsing.dart';
import 'song.dart';

/// 云盘容量信息。
class CloudDriveInfo {
  const CloudDriveInfo({
    this.totalCount,
    this.usedBytes,
    this.availableBytes,
    this.maxBytes,
  });

  final int? totalCount;
  final int? usedBytes;
  final int? availableBytes;
  final int? maxBytes;

  double get usageRatio {
    final used = usedBytes ?? 0;
    final max = maxBytes ?? 0;
    if (max <= 0) return 0;
    return (used / max).clamp(0.0, 1.0);
  }

  factory CloudDriveInfo.fromJson(Map<String, dynamic> json) {
    return CloudDriveInfo(
      totalCount: asInt(json['list_count']),
      usedBytes: asInt(json['used_size']),
      availableBytes: asInt(json['availble_size'] ?? json['available_size']),
      maxBytes: asInt(json['max_size']),
    );
  }
}

/// 云盘歌曲分页结果。
class CloudDriveResult {
  const CloudDriveResult({required this.info, required this.songs});

  final CloudDriveInfo info;
  final List<Song> songs;
}

/// 云盘歌曲的额外元数据（文件大小、比特率、扩展名等）。
class CloudDriveSongMeta {
  const CloudDriveSongMeta({
    required this.song,
    this.fileSize,
    this.bitrate,
    this.fileExt,
    this.addedAt,
  });

  final Song song;
  final int? fileSize;
  final int? bitrate;
  final String? fileExt;
  final DateTime? addedAt;

  factory CloudDriveSongMeta.fromJson(Map<String, dynamic> json) {
    final albumInfo = asMap(json['album_info']);
    final authorsRaw = asList(
      json['authors'],
    ).whereType<Map<String, dynamic>>();
    final artists = authorsRaw
        .map(
          (item) => ArtistRef(
            id: asString(item['author_id']) ?? '',
            name: asString(item['author_name']) ?? '',
            avatarUrl: normalizeImageUrl(asString(item['sizable_avatar'])),
          ),
        )
        .where((artist) => artist.name.isNotEmpty)
        .toList();
    final authorName = asString(json['author_name']);
    if (artists.isEmpty && authorName != null && authorName.isNotEmpty) {
      final names = authorName
          .split(RegExp(r'\s*[/、,，&]\s*'))
          .where((name) => name.trim().isNotEmpty);
      for (final name in names) {
        artists.add(ArtistRef(id: '', name: name.trim()));
      }
    }
    final artistName = artists.map((artist) => artist.name).join(' / ');

    // 云盘歌曲的 name 字段通常是上传时的文件名（如 "xxx.mp3"），这里移除后缀。
    final ext = asString(json['ext']);
    final rawName =
        asString(json['name']) ?? asString(json['audio_name']) ?? '';
    final cleanName = _stripCloudFileExtension(rawName, ext);
    final resolvedArtist = artistName.isNotEmpty
        ? artistName
        : authorName ?? '未知艺人';
    final cleanedTitle = cleanSongTitle(
      cleanName.isNotEmpty ? cleanName : '未知歌曲',
      artist: resolvedArtist,
      artists: artists,
    );

    final song = Song(
      id:
          asString(json['audio_id']) ??
          asString(json['album_audio_id']) ??
          asString(json['hash']) ??
          '',
      title: cleanedTitle,
      rawTitle: rawName,
      artist: resolvedArtist,
      hash: asString(json['hash']) ?? asString(json['hash_std']) ?? '',
      albumId: asString(albumInfo['album_id']),
      albumAudioId:
          asString(json['album_audio_id']) ?? asString(json['audio_id']),
      albumName: asString(albumInfo['album_name']),
      coverUrl: normalizeImageUrl(asString(albumInfo['sizable_cover'])),
      artists: artists,
      duration: durationFromMilliseconds(json['timelen']),
      isCloudDrive: true,
    );

    final addTime = asInt(json['add_time']);
    return CloudDriveSongMeta(
      song: song,
      fileSize: asInt(json['size']),
      bitrate: asInt(json['bitrate']),
      fileExt: ext,
      addedAt: addTime == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(addTime * 1000),
    );
  }
}

/// 移除云盘歌曲文件名的后缀。
///
/// 优先按服务端返回的 `ext` 字段移除；若无则按常见音频后缀兜底。
String _stripCloudFileExtension(String name, String? ext) {
  if (ext != null && ext.isNotEmpty) {
    final normalizedExt = ext.startsWith('.') ? ext : '.$ext';
    if (name.toLowerCase().endsWith(normalizedExt.toLowerCase())) {
      return name.substring(0, name.length - normalizedExt.length);
    }
  }
  final dot = name.lastIndexOf('.');
  if (dot > 0) {
    final possibleExt = name.substring(dot).toLowerCase();
    if (const [
      '.mp3',
      '.flac',
      '.wav',
      '.m4a',
      '.aac',
      '.ogg',
    ].contains(possibleExt)) {
      return name.substring(0, dot);
    }
  }
  return name;
}
