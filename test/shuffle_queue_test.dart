import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/controllers/shuffle_queue.dart';

void main() {
  group('ShuffleQueue 算法与循环调度测试', () {
    test('空队列与单曲队列边界测试', () {
      final shuffle = ShuffleQueue();
      expect(shuffle.next(0), -1);
      expect(shuffle.previous(0), -1);

      expect(shuffle.next(1), 0);
      expect(shuffle.previous(1), 0);
    });

    test('一整轮内无重复播放每一首歌', () {
      final shuffle = ShuffleQueue();
      const length = 20;

      // 重置并以第 5 首为当前首
      shuffle.reset(length, currentIndex: 5);
      expect(shuffle.cursor, 0);
      expect(shuffle.indices.first, 5);
      expect(shuffle.indices.toSet().length, length);

      final playedIndices = <int>[shuffle.indices.first];

      // 连续调用 next 19 次，走完本轮剩余的 19 首
      for (var i = 0; i < length - 1; i++) {
        final nextIndex = shuffle.next(length);
        playedIndices.add(nextIndex);
      }

      // 验证一整轮内每首歌都被播放且仅播放恰好 1 次
      expect(playedIndices.length, length);
      expect(playedIndices.toSet().length, length);
      for (var i = 0; i < length; i++) {
        expect(playedIndices.contains(i), isTrue);
      }
    });

    test('两轮衔接时首尾防撞（新一轮第一首不等于上一轮最后一首）', () {
      final shuffle = ShuffleQueue();
      const length = 10;
      shuffle.reset(length);

      // 播完第一轮
      for (var i = 0; i < length - 1; i++) {
        shuffle.next(length);
      }
      final lastOfFirstRound = shuffle.indices.last;

      // 跨入第二轮的第一首
      final firstOfSecondRound = shuffle.next(length);

      expect(firstOfSecondRound, isNot(equals(lastOfFirstRound)));
    });

    test('「上一首」精确回退到前序播放歌曲', () {
      final shuffle = ShuffleQueue();
      const length = 15;
      shuffle.reset(length, currentIndex: 2);

      // 前进 3 首
      final track1 = shuffle.next(length);
      final track2 = shuffle.next(length);
      final track3 = shuffle.next(length);

      expect(track3, isNot(equals(track2)));
      expect(track2, isNot(equals(track1)));

      // 往回退 2 首
      expect(shuffle.previous(length), track2);
      expect(shuffle.previous(length), track1);
    });

    test('外部点播歌单中任意单曲后平滑对齐', () {
      final shuffle = ShuffleQueue();
      const length = 12;
      shuffle.reset(length);

      // 用户在播放列表中手动点了第 8 首歌
      shuffle.syncCurrentIndex(length, 8);
      expect(shuffle.indices[shuffle.cursor], 8);

      // 接下来按下一首，应该顺着后续元素播放，而不是重头开始
      final nextSong = shuffle.next(length);
      expect(nextSong, isNot(equals(8)));
      expect(shuffle.indices[shuffle.cursor], nextSong);
    });
  });
}
