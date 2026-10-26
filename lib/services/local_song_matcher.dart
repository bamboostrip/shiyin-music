import '../models/music_models.dart';

/// 剥离歌名开头的「歌手名 - 」前缀。
///
/// 移植自上游 kgka_Music_hl 3.2.0（`87c35a1`，上游位于 models 层）。fork 没有
/// 同名工具函数，随本地歌曲匹配服务一起提供，规则与上游保持一致：支持
/// `A / B`、`A、B`、`A & B` 等多歌手写法，分隔符与空白容错，匹配不到时原样返回。
String stripArtistNamePrefix(String title, String artistName) {
  if (artistName.isEmpty) {
    return title;
  }
  final names = artistName.split(' / ').where((name) => name.isNotEmpty);
  final candidates = [
    RegExp.escape(artistName),
    names.map(RegExp.escape).join(r'\s*[/、&_,，–—-]?\s*'),
  ];
  for (final candidate in candidates) {
    final match = RegExp('^$candidate\\s*[-–—]\\s*').firstMatch(title);
    if (match != null && match.end < title.length) {
      return title.substring(match.end);
    }
  }
  return title;
}

/// 本地歌曲的「可匹配身份」。
///
/// 本地文件的路径不是酷狗 hash，不能直接当歌词查询参数；先用元数据（标题/
/// 歌手/时长）在酷狗搜索里找同一首歌，再拿匹配结果的 hash 拉歌词。
///
/// 移植自上游 kgka_Music_hl 3.2.0（`87c35a1` / `dc92cfd`），匹配规则宁缺毋滥：
/// - 标题 normalize 后必须完全相等；
/// - 已知歌手时，候选歌手集合必须包含期望歌手（全部）；
/// - 未知歌手时必须有时长且差值 ≤ 3 秒，避免同名不同录音；
/// - 有时长时差值 > 8 秒直接丢弃。
class LocalSongIdentity {
  const LocalSongIdentity(this.title, this.artist, this.duration);

  factory LocalSongIdentity.fromSong(Song song) {
    var title = song.title.trim();
    var artist = song.artist.trim();
    if (_isUnknown(artist)) artist = '';
    if (_isUnknown(title)) {
      // 媒体库/文件标签缺失时退化为文件名（本地歌曲 id 即文件路径）。
      title = song.id.replaceAll('\\', '/').split('/').last;
    }
    title = title.replaceFirst(
      RegExp(
        r'\.(mp3|flac|m4a|ogg|opus|wav|aac|ape|wma)$',
        caseSensitive: false,
      ),
      '',
    );
    if (artist.isNotEmpty) {
      title = stripArtistNamePrefix(title, artist);
    } else {
      // MediaStore 有时把「歌手 - 歌名」整体塞进 title 字段。
      final parts = title.split(' - ');
      if (parts.length == 2 && parts.every((part) => part.trim().isNotEmpty)) {
        artist = parts.first.trim();
        title = parts.last.trim();
      }
    }
    return LocalSongIdentity(title.trim(), artist, song.duration);
  }

  final String title;
  final String artist;
  final Duration? duration;

  String get query => [artist, title].where((s) => s.isNotEmpty).join(' ');

  bool get isSearchable => !_isUnknown(title) && _normalize(title).isNotEmpty;

  List<Song> matchCandidates(List<Song> songs) {
    final ranked = <({Song song, int delta})>[];
    final seen = <String>{};
    for (final song in songs) {
      if (song.source != SongSource.kugou ||
          song.hash.isEmpty ||
          !seen.add(song.hash) ||
          _normalize(song.title) != _normalize(title)) {
        continue;
      }
      final expectedArtists = _artists(artist);
      final actualArtists = _artists(song.artist);
      if (expectedArtists.isNotEmpty &&
          !actualArtists.containsAll(expectedArtists)) {
        continue;
      }
      final hasDurations =
          duration != null &&
          duration! > Duration.zero &&
          song.duration != null &&
          song.duration! > Duration.zero;
      final delta = hasDurations
          ? (duration! - song.duration!).inMilliseconds.abs()
          : 1 << 30;
      // 未知歌手必须有接近的时长；否则宁可没有歌词，也不给同名的另一版录音。
      if (expectedArtists.isEmpty && (!hasDurations || delta > 3000)) continue;
      if (hasDurations && delta > 8000) continue;
      ranked.add((song: song, delta: delta));
    }
    ranked.sort((a, b) => a.delta.compareTo(b.delta));
    return ranked.map((entry) => entry.song).toList();
  }

  static Set<String> _artists(String value) => value
      .split(RegExp(r'\s*[/、&;；]\s*'))
      .where((name) => !_isUnknown(name))
      .map(_normalize)
      .where((name) => name.isNotEmpty)
      .toSet();

  static bool _isUnknown(String value) => const {
    '',
    '未知歌曲',
    '未知艺人',
    '未知歌手',
    '未知艺术家',
    '<unknown>',
    'unknown',
  }.contains(value.trim().toLowerCase());

  // 保留 Live / 伴奏 / Remix 等版本词，只忽略标点与空白：
  // 「Test Song」与「Test Song (Live)」必须是两首歌，不能互相匹配。
  static String _normalize(String value) => value
      .replaceAll(RegExp(r'<[^>]*>'), '')
      .toLowerCase()
      .replaceAll(RegExp(r'''[\s\-_.·,，。:：'"“”‘’!！?？()（）\[\]【】]'''), '');
}
