import 'dart:math' as math;

/// 随机播放洗牌队列（基于 Fisher-Yates 算法的无放回乱序队列）。
///
/// 核心特性：
/// 1. **一轮之内绝不重复**：在播满歌单长度之前，每首歌曲必然且仅会被调度恰好一次。
/// 2. **两轮之间首尾防撞**：一轮播完自动重新洗牌时，确保新一轮的第一首不等于上一轮的最后一首。
/// 3. **「上一首」精确回退**：记录已播放的乱序游标，点击上一首能够回到刚刚听过的那首歌。
/// 4. **外部点歌智能对齐**：用户从歌单中随意点播某首歌曲，游标平滑定位，不破坏后续的无重复体验。
class ShuffleQueue {
  ShuffleQueue({math.Random? random}) : _random = random ?? math.Random();

  final math.Random _random;

  List<int> _indices = const [];
  int _cursor = -1;

  /// 当前乱序索引列表（只读）。
  List<int> get indices => List.unmodifiable(_indices);

  /// 当前游标在乱序列表中的位置。
  int get cursor => _cursor;

  /// 当前洗牌队列容量。
  int get length => _indices.length;

  /// 基于队列长度重建洗牌序列。
  ///
  /// - [currentIndex]: 当前正在播放的歌曲在原队列中的索引。若提供，则将其置于洗牌序列的第 0 位（游标设为 0）。
  /// - [avoidFirstIndex]: 重新洗牌时应尽量避免排在第 0 位的索引（用于跨轮次防重）。
  void reset(int queueLength, {int? currentIndex, int? avoidFirstIndex}) {
    if (queueLength <= 0) {
      _indices = const [];
      _cursor = -1;
      return;
    }
    if (queueLength == 1) {
      _indices = const [0];
      _cursor = 0;
      return;
    }

    final list = List<int>.generate(queueLength, (i) => i);
    // Fisher-Yates 洗牌算法
    for (var i = queueLength - 1; i > 0; i--) {
      final j = _random.nextInt(i + 1);
      final temp = list[i];
      list[i] = list[j];
      list[j] = temp;
    }

    if (currentIndex != null && currentIndex >= 0 && currentIndex < queueLength) {
      list.remove(currentIndex);
      list.insert(0, currentIndex);
      _cursor = 0;
    } else if (avoidFirstIndex != null && queueLength > 1) {
      if (list.first == avoidFirstIndex) {
        final swapTarget = queueLength > 2 ? 1 + _random.nextInt(queueLength - 1) : 1;
        final temp = list[0];
        list[0] = list[swapTarget];
        list[swapTarget] = temp;
      }
      _cursor = 0;
    } else {
      _cursor = 0;
    }

    _indices = list;
  }

  /// 同步用户在原队列中点播的索引。
  ///
  /// 如果洗牌序列有效且包含此索引，则游标跳转到该位置；
  /// 否则触发全量洗牌并以该索引为起点。
  void syncCurrentIndex(int queueLength, int targetIndex) {
    if (_indices.length != queueLength) {
      reset(queueLength, currentIndex: targetIndex);
      return;
    }

    final pos = _indices.indexOf(targetIndex);
    if (pos >= 0) {
      _cursor = pos;
    } else {
      reset(queueLength, currentIndex: targetIndex);
    }
  }

  /// 获取下一首在原队列中的索引。
  ///
  /// 播完一轮后自动重新洗牌，并做首尾防重处理。
  int next(int queueLength) {
    if (queueLength <= 0) return -1;
    if (queueLength == 1) return 0;

    if (_indices.length != queueLength || _cursor < 0) {
      reset(queueLength);
    }

    _cursor++;
    if (_cursor >= _indices.length) {
      final last = _indices.isNotEmpty ? _indices.last : null;
      reset(queueLength, avoidFirstIndex: last);
      _cursor = 0;
    }

    return _indices[_cursor];
  }

  /// 获取上一首在原队列中的索引。
  ///
  /// 精确回退到刚才播放的乱序前序歌曲；若已在第 0 首，回绕到打乱列表末尾。
  int previous(int queueLength) {
    if (queueLength <= 0) return -1;
    if (queueLength == 1) return 0;

    if (_indices.length != queueLength || _cursor < 0) {
      reset(queueLength);
    }

    if (_cursor > 0) {
      _cursor--;
    } else {
      _cursor = _indices.length - 1;
    }

    return _indices[_cursor];
  }
}
