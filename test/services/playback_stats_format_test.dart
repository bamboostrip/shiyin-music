import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/services/playback_stats_service.dart';

void main() {
  test('听歌时长格式化：不足 1 分钟显示秒数', () {
    expect(const PlaybackStats().formattedListenTime, '0秒');
    expect(
      const PlaybackStats(totalListenTime: Duration(seconds: 42))
          .formattedListenTime,
      '42秒',
    );
    expect(
      const PlaybackStats(totalListenTime: Duration(minutes: 3))
          .formattedListenTime,
      '3分钟',
    );
    expect(
      const PlaybackStats(
        totalListenTime: Duration(hours: 2, minutes: 7),
      ).formattedListenTime,
      '2小时7分钟',
    );
  });
}
