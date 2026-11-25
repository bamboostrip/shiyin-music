import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/widgets/apple_lyrics/controllers/lyric_scroll_controller.dart';

void main() {
  test('resumeFollowNow 立即结束浏览/等待回弹态', () {
    final controller = LyricScrollController();
    controller.setViewportSize(const Size(360, 600));
    controller.setCurrentLine(3, isSeeking: false, lineHeight: 40);

    controller.onUserScroll(120);
    expect(controller.isUserScrolling, isTrue);
    expect(controller.isWaitingForAutoReturn, isFalse);

    controller.onUserScrollEnd();
    expect(controller.isUserScrolling, isFalse);
    expect(
      controller.isWaitingForAutoReturn,
      isTrue,
      reason: '松手后进入 5s 自动回弹倒计时',
    );

    controller.resumeFollowNow();
    expect(controller.isUserScrolling, isFalse);
    expect(
      controller.isWaitingForAutoReturn,
      isFalse,
      reason: '点击歌词跳播应立即退出浏览态，不等倒计时',
    );
  });
}
