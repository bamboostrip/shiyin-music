import 'model_parsing.dart';
import 'song.dart';

/// 云端播放记录：酷狗账号级听歌历史中的一条。
class CloudPlayRecord {
  const CloudPlayRecord({required this.song, this.playedAt});

  final Song song;

  /// 服务端记录的播放时间；缺失时为 null（归入「未知时间」分组）。
  final DateTime? playedAt;
}

/// 按自然日聚合的一组云端播放记录。
class CloudPlayDayGroup {
  const CloudPlayDayGroup({required this.label, required this.records});

  /// 分组标题（今天 / 昨天 / M月d日 / yyyy年M月d日 / 未知时间）。
  final String label;
  final List<CloudPlayRecord> records;
}

/// 云端播放历史：酷狗服务端返回的账号听歌记录集合。
///
/// `/playhistory/v1/get_songs` 的真实响应形状未经真机验证，
/// [fromJson] 对承载结构做容错探测（根数组 / list / songs / data.list），
/// 任何无法识别的形状都返回空集合而不是抛异常。
class CloudPlayHistory {
  const CloudPlayHistory({this.records = const []});

  final List<CloudPlayRecord> records;

  factory CloudPlayHistory.fromJson(Object? raw) {
    final parsed = <CloudPlayRecord>[];
    for (final map in _recordMaps(raw)) {
      final record = _parseRecord(map);
      if (record != null) parsed.add(record);
    }
    return CloudPlayHistory(records: parsed);
  }

  int get totalRecords => records.length;

  /// 所有记录中最早的非空播放时间（页面摘要「最早可回到」用）。
  DateTime? get earliestPlayedAt {
    DateTime? earliest;
    for (final record in records) {
      final time = record.playedAt;
      if (time != null && (earliest == null || time.isBefore(earliest))) {
        earliest = time;
      }
    }
    return earliest;
  }

  /// 按自然日倒序分组；组内按播放时间倒序；无时间的记录归末尾组。
  List<CloudPlayDayGroup> groupByDay({DateTime? now}) {
    if (records.isEmpty) return const [];
    final nowResolved = now ?? DateTime.now();
    final today = DateTime(nowResolved.year, nowResolved.month, nowResolved.day);

    final buckets = <DateTime, List<CloudPlayRecord>>{};
    final unknown = <CloudPlayRecord>[];
    for (final record in records) {
      final time = record.playedAt;
      if (time == null) {
        unknown.add(record);
        continue;
      }
      final day = DateTime(time.year, time.month, time.day);
      buckets.putIfAbsent(day, () => []).add(record);
    }

    final days = buckets.keys.toList()..sort((a, b) => b.compareTo(a));
    return [
      for (final day in days)
        CloudPlayDayGroup(
          label: _dayLabel(day, today),
          records: (buckets[day]!
                ..sort((a, b) => b.playedAt!.compareTo(a.playedAt!)))
              .toList(),
        ),
      if (unknown.isNotEmpty) CloudPlayDayGroup(label: '未知时间', records: unknown),
    ];
  }

  static String _dayLabel(DateTime day, DateTime today) {
    final diffDays = today.difference(day).inDays;
    if (diffDays == 0) return '今天';
    if (diffDays == 1) return '昨天';
    final yearPrefix = day.year == today.year ? '' : '${day.year}年';
    return '$yearPrefix${day.month}月${day.day}日';
  }

  /// 记录数组的候选承载键。真实形状未验证，按常见程度排列。
  static const _listKeys = ['list', 'songs', 'history', 'records'];

  static Iterable<Map<String, dynamic>> _recordMaps(Object? raw) {
    if (raw is List) {
      return raw.whereType<Map<String, dynamic>>();
    }
    final map = asMap(raw);
    if (map.isEmpty) return const [];
    for (final key in [..._listKeys, 'data']) {
      final value = map[key];
      if (value is List) return value.whereType<Map<String, dynamic>>();
    }
    // 一层嵌套：{data: {list: [...]}}
    final dataMap = asMap(map['data']);
    for (final key in _listKeys) {
      final value = dataMap[key];
      if (value is List) return value.whereType<Map<String, dynamic>>();
    }
    return const [];
  }

  static CloudPlayRecord? _parseRecord(Map<String, dynamic> map) {
    // 歌曲字段可能平铺在记录上，也可能嵌在 song / audio_info 下。
    final songMap = asMap(map['song']).isNotEmpty
        ? asMap(map['song'])
        : asMap(map['audio_info']).isNotEmpty
            ? asMap(map['audio_info'])
            : map;
    final song = Song.fromSearch(songMap);
    if (song.hash.isEmpty) return null;
    return CloudPlayRecord(song: song, playedAt: _parseTime(map, songMap));
  }

  static const _timeKeys = [
    'time', 'addtime', 'add_time', 'play_time', 'ot',
    'createtime', 'create_time', 'timestamp',
  ];

  static DateTime? _parseTime(
    Map<String, dynamic> record,
    Map<String, dynamic> song,
  ) {
    for (final source in [record, song]) {
      for (final key in _timeKeys) {
        final value = asInt(source[key]);
        if (value == null || value <= 0) continue;
        // 秒级（约 1e9）与毫秒级（约 1e12）统一折算成毫秒。
        final ms = value > 9999999999 ? value : value * 1000;
        // 合理性区间约 2000–2100 年：候选键若实际承载歌曲时长
        // （如 245 秒 / 245000 毫秒）或微秒级脏值（约 1e15），折算后
        // 都落不进该区间，跳过该键，避免记录被归进 1970 或远未来分组。
        if (ms < 946684800000 || ms > 4102444800000) continue;
        return DateTime.fromMillisecondsSinceEpoch(ms);
      }
    }
    return null;
  }
}
