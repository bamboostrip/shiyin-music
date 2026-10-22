import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/models/music_models.dart';

/// `CloudPlayHistory` 容错解析与按日分组的契约测试。
///
/// 背景：酷狗 `/playhistory/v1/get_songs` 的真实响应形状未经真机验证，
/// 解析器必须同时容忍「根即数组 / list / songs / data.list 嵌套」等
/// 常见承载方式，且任何未知形状都不抛异常、返回空。
void main() {
  group('CloudPlayHistory.fromJson 容错解析', () {
    test('根即记录数组：平铺歌曲字段 + 秒级时间戳', () {
      final history = CloudPlayHistory.fromJson([
        {
          'hash': 'abc123',
          'filename': '周杰伦 - 晴天',
          'singername': '周杰伦',
          'songname': '晴天',
          'time': 1729500000,
        },
      ]);

      expect(history.totalRecords, 1);
      expect(history.records.first.song.hash, 'abc123');
      expect(history.records.first.song.title, '晴天');
      expect(history.records.first.playedAt,
          DateTime.fromMillisecondsSinceEpoch(1729500000 * 1000));
    });

    test('list 键承载 + 记录内嵌 song 对象 + 毫秒时间戳', () {
      final history = CloudPlayHistory.fromJson({
        'status': 1,
        'list': [
          {
            'time': 1729500000123,
            'song': {
              'FileHash': 'hash9',
              'OriSongName': '七里香',
              'SingerName': '周杰伦',
              'MixSongID': 12345,
              'Image': 'https://imge.kugou.com/aa/{size}/x.jpg',
            },
          },
        ],
      });

      expect(history.totalRecords, 1);
      expect(history.records.first.song.hash, 'hash9');
      expect(history.records.first.song.title, '七里香');
      expect(history.records.first.playedAt!.millisecondsSinceEpoch,
          1729500000123);
    });

    test('data.list 一层嵌套承载', () {
      final history = CloudPlayHistory.fromJson({
        'status': 1,
        'data': {
          'list': [
            {'hash': 'h1', 'songname': '歌1', 'singername': '人1', 'time': 100},
          ],
        },
      });

      expect(history.totalRecords, 1);
    });

    test('时间字段多候选：ot/addtime/createtime 任一存在即可解析', () {
      final history = CloudPlayHistory.fromJson({
        'list': [
          {'hash': 'a', 'songname': 'A', 'ot': 1729500000},
          {'hash': 'b', 'songname': 'B', 'addtime': '1729600000'},
          {'hash': 'c', 'songname': 'C', 'createtime': 1729700000},
        ],
      });

      expect(history.records.length, 3);
      expect(history.records.every((r) => r.playedAt != null), isTrue);
    });

    test('时间键承载歌曲时长（秒/毫秒）或微秒脏值 → 判为非时间戳', () {
      // 候选键若其实是时长字段，不能折算成 1970 年附近的「播放时间」。
      final history = CloudPlayHistory.fromJson({
        'list': [
          {'hash': 'a', 'songname': 'A', 'time': 245},
          {'hash': 'b', 'songname': 'B', 'time': 245000},
          {'hash': 'c', 'songname': 'C', 'time': 1729500000123456},
        ],
      });

      expect(history.totalRecords, 3);
      expect(history.records.every((r) => r.playedAt == null), isTrue);
      // 无一落入 1970/远未来日期分组，全部归「未知时间」。
      final groups = history.groupByDay(now: DateTime(2026, 10, 22));
      expect(groups.map((g) => g.label), ['未知时间']);
    });

    test('无 hash 的脏记录被过滤，不影响其余记录', () {
      final history = CloudPlayHistory.fromJson({
        'list': [
          {'hash': '', 'songname': '脏数据'},
          {'hash': 'ok', 'songname': '正常', 'singername': '歌手'},
        ],
      });

      expect(history.totalRecords, 1);
      expect(history.records.first.song.title, '正常');
    });

    test('未知形状不抛异常：空 Map / 纯字符串 / 空数组 / 失败信封都返回空', () {
      expect(CloudPlayHistory.fromJson(const {}).totalRecords, 0);
      expect(CloudPlayHistory.fromJson('oops').totalRecords, 0);
      expect(CloudPlayHistory.fromJson(const []).totalRecords, 0);
      // 失败信封（status!=1）不在解析层抛错——那是 API 层的职责。
      expect(
        CloudPlayHistory.fromJson({'status': 0, 'error_code': 30195}).totalRecords,
        0,
      );
    });

    test('earliestPlayedAt 取所有记录中最早的非空时间', () {
      final history = CloudPlayHistory.fromJson({
        'list': [
          {'hash': 'a', 'songname': 'A', 'time': 1729900000},
          {'hash': 'b', 'songname': 'B', 'time': 1729500000},
          {'hash': 'c', 'songname': 'C'}, // 无时间
        ],
      });

      expect(
          history.earliestPlayedAt!.millisecondsSinceEpoch, 1729500000 * 1000);
    });
  });

  group('CloudPlayHistory.groupByDay 按日分组', () {
    CloudPlayRecord rec(String hash, int? ts) => CloudPlayRecord(
          song: Song(
            id: hash, title: 'T$hash', artist: '歌手', hash: hash,
          ),
          playedAt: ts == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch(ts),
        );

    test('今天/昨天标签、组内按时间倒序、组间按日期倒序', () {
      final now = DateTime(2026, 10, 22, 20, 0);
      final todayNoon = DateTime(2026, 10, 22, 12, 0);
      final todayMorning = DateTime(2026, 10, 22, 8, 0);
      final yesterday = DateTime(2026, 10, 21, 10, 0);
      final history = CloudPlayHistory(records: [
        rec('a', yesterday.millisecondsSinceEpoch),
        rec('b', todayMorning.millisecondsSinceEpoch),
        rec('c', todayNoon.millisecondsSinceEpoch),
      ]);

      final groups = history.groupByDay(now: now);

      expect(groups.map((g) => g.label).toList(), ['今天', '昨天']);
      expect(groups.first.records.map((r) => r.song.hash).toList(),
          ['c', 'b']);
      expect(groups.last.records.single.song.hash, 'a');
    });

    test('跨年日期带年份，同年只显示 M月d日', () {
      final now = DateTime(2026, 10, 22);
      final history = CloudPlayHistory(records: [
        rec('x', DateTime(2024, 5, 1).millisecondsSinceEpoch),
        rec('y', DateTime(2026, 3, 8).millisecondsSinceEpoch),
      ]);

      final labels = history.groupByDay(now: now).map((g) => g.label).toList();
      expect(labels, ['3月8日', '2024年5月1日']);
    });

    test('无时间戳的记录归入末尾「未知时间」组', () {
      final history = CloudPlayHistory(records: [
        rec('no-time', null),
        rec('timed', DateTime(2026, 10, 22).millisecondsSinceEpoch),
      ]);

      final groups = history.groupByDay(now: DateTime(2026, 10, 22));
      expect(groups.last.label, '未知时间');
      expect(groups.last.records.single.song.hash, 'no-time');
      expect(groups.first.label, '今天');
    });

    test('空记录返回空分组列表', () {
      expect(const CloudPlayHistory().groupByDay(), isEmpty);
    });
  });
}
