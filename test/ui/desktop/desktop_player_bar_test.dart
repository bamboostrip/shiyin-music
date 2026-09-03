import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/ui/desktop/desktop_player_bar.dart';

void main() {
  group('formatDuration', () {
    test('分秒补零', () {
      expect(formatDuration(Duration.zero), '00:00');
      expect(formatDuration(const Duration(seconds: 65)), '01:05');
      expect(formatDuration(const Duration(minutes: 9, seconds: 9)), '09:09');
    });
    test('超过一小时显示小时位', () {
      expect(
        formatDuration(const Duration(hours: 1, minutes: 1, seconds: 15)),
        '1:01:15',
      );
    });
  });
}
