// 系统媒体会话歌词用的标准 LRC 格式化纯函数：
//   1. 时间标签 mm:ss.xx（补零 / 厘秒截断 / 负值兜底 / 超 1 小时不回绕）；
//   2. 整首拼接：行间 \n、间奏空行保留时间轴、空列表返回 null；
//   3. 翻译/音译不混进 LRC 正文（走 MediaSession 独立字段）。
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/services/lrc_formatter.dart';

void main() {
  group('LrcFormatter.formatTimestamp', () {
    test('零值输出 00:00.00（分钟/秒/厘秒都补零）', () {
      expect(LrcFormatter.formatTimestamp(Duration.zero), '00:00.00');
    });

    test('满分钟进位并补零：65.123s → 01:05.12', () {
      expect(
        LrcFormatter.formatTimestamp(
          const Duration(minutes: 1, seconds: 5, milliseconds: 123),
        ),
        '01:05.12',
      );
    });

    test('毫秒按 10ms 截断（不四舍五入）：1.999s → 00:01.99', () {
      expect(
        LrcFormatter.formatTimestamp(const Duration(milliseconds: 1999)),
        '00:01.99',
      );
      expect(
        LrcFormatter.formatTimestamp(const Duration(milliseconds: 1999)),
        isNot('00:02.00'),
        reason: '向上取整会让相邻行在边界处抢同一时刻',
      );
    });

    test('负值按 0 处理（偏移/脏数据不产生非法标签）', () {
      expect(
        LrcFormatter.formatTimestamp(const Duration(seconds: -3)),
        '00:00.00',
      );
    });

    test('超过 1 小时不回绕：3661s → 61:01.00', () {
      expect(
        LrcFormatter.formatTimestamp(const Duration(seconds: 3661)),
        '61:01.00',
        reason: '标准 LRC 的 mm 允许大于 59；上游 remainder(60) 会回绕成 01:01',
      );
    });
  });

  group('LrcFormatter.buildFullLrc', () {
    test('标准 LRC 行拼接：行间 \\n、时间标签 + 正文', () {
      const lines = [
        LyricLine(time: Duration.zero, text: '第一句'),
        LyricLine(time: Duration(seconds: 5), text: '第二句'),
        LyricLine(
          time: Duration(minutes: 1, seconds: 2, milliseconds: 340),
          text: '第三句',
        ),
      ];
      expect(
        LrcFormatter.buildFullLrc(lines),
        '[00:00.00]第一句\n[00:05.00]第二句\n[01:02.34]第三句',
      );
    });

    test('空文本行保留时间标签（间奏占位，时间轴不断档）', () {
      const lines = [
        LyricLine(time: Duration.zero, text: '第一句'),
        LyricLine(time: Duration(seconds: 5), text: ''),
        LyricLine(time: Duration(seconds: 10), text: '第三句'),
      ];
      expect(
        LrcFormatter.buildFullLrc(lines),
        '[00:00.00]第一句\n[00:05.00]\n[00:10.00]第三句',
      );
    });

    test('空列表返回 null（调用方据此清空歌词元数据）', () {
      expect(LrcFormatter.buildFullLrc(const []), isNull);
    });

    test('翻译/音译不写入 LRC 正文（避免第三方插件按行错位）', () {
      const lines = [
        LyricLine(
          time: Duration.zero,
          text: '第一句',
          translation: 'first line',
          romanization: 'dai yi ju',
        ),
      ];
      final lrc = LrcFormatter.buildFullLrc(lines);
      expect(lrc, '[00:00.00]第一句');
      expect(lrc, isNot(contains('first line')));
      expect(lrc, isNot(contains('dai yi ju')));
    });

    test('歌词行数较多时保持每行一个时间标签', () {
      final lines = [
        for (var i = 0; i < 20; i++)
          LyricLine(
            time: Duration(seconds: i),
            text: '第$i句',
          ),
      ];
      final lrc = LrcFormatter.buildFullLrc(lines)!;
      expect('\n'.allMatches(lrc).length, 19);
      expect(lrc.startsWith('[00:00.00]第0句'), isTrue);
      expect(lrc.endsWith('[00:19.00]第19句'), isTrue);
    });
  });
}
