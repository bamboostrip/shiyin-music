import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/controllers/player_logic.dart';
import 'package:shiyin_music/models/music_models.dart';

void main() {
  group('PlayerLyricLogic.activeIndex（歌词定位，锁定原 activeLyricIndex 行为）', () {
    const lines = [
      LyricLine(time: Duration(seconds: 1), text: 'a'),
      LyricLine(time: Duration(seconds: 5), text: 'b'),
      LyricLine(time: Duration(seconds: 9), text: 'c'),
    ];

    test('空歌词返回 -1', () {
      expect(PlayerLyricLogic.activeIndex(const [], Duration.zero), -1);
    });

    test('进度在第一行之前时定位到第 0 行', () {
      expect(PlayerLyricLogic.activeIndex(lines, Duration.zero), 0);
    });

    test('进度落在某行时间点上及之后时定位到该行', () {
      expect(
        PlayerLyricLogic.activeIndex(lines, const Duration(seconds: 1)),
        0,
      );
      expect(
        PlayerLyricLogic.activeIndex(
          lines,
          const Duration(seconds: 4, milliseconds: 999),
        ),
        0,
      );
      expect(
        PlayerLyricLogic.activeIndex(lines, const Duration(seconds: 5)),
        1,
      );
      expect(
        PlayerLyricLogic.activeIndex(lines, const Duration(seconds: 9)),
        2,
      );
      expect(
        PlayerLyricLogic.activeIndex(lines, const Duration(seconds: 100)),
        2,
      );
    });
  });

  group(
    'PlayerLyricLogic.estimatedLineDuration（行时长估算，锁定原 _estimatedLineDuration 行为）',
    () {
      const lines = [
        LyricLine(time: Duration.zero, text: 'a'),
        LyricLine(
          time: Duration(seconds: 5),
          text: 'b',
          duration: Duration(seconds: 2),
        ),
        LyricLine(time: Duration(seconds: 10), text: 'c'),
      ];

      test('索引越界返回 null', () {
        expect(
          PlayerLyricLogic.estimatedLineDuration(
            lines,
            const Duration(seconds: 30),
            -1,
          ),
          isNull,
        );
        expect(
          PlayerLyricLogic.estimatedLineDuration(
            lines,
            const Duration(seconds: 30),
            3,
          ),
          isNull,
        );
      });

      test('有显式行时长（>0）时优先使用', () {
        expect(
          PlayerLyricLogic.estimatedLineDuration(
            lines,
            const Duration(seconds: 30),
            1,
          ),
          const Duration(seconds: 2),
        );
      });

      test('无显式时长时用下一行起始时间差', () {
        expect(
          PlayerLyricLogic.estimatedLineDuration(
            lines,
            const Duration(seconds: 30),
            0,
          ),
          const Duration(seconds: 5),
        );
      });

      test('最后一行用歌曲总时长减行起始时间的尾段', () {
        expect(
          PlayerLyricLogic.estimatedLineDuration(
            lines,
            const Duration(seconds: 30),
            2,
          ),
          const Duration(seconds: 20),
        );
      });

      test('总时长不大于行起始时间且无其它依据时返回 null', () {
        expect(
          PlayerLyricLogic.estimatedLineDuration(
            lines,
            const Duration(seconds: 8),
            2,
          ),
          isNull,
        );
      });

      test('显式时长为 0 且下一行同时开始时回退到尾段', () {
        const zeroGap = [
          LyricLine(time: Duration.zero, text: 'a', duration: Duration.zero),
          LyricLine(time: Duration.zero, text: 'b'),
        ];
        expect(
          PlayerLyricLogic.estimatedLineDuration(
            zeroGap,
            const Duration(seconds: 7),
            0,
          ),
          const Duration(seconds: 7),
        );
        expect(
          PlayerLyricLogic.estimatedLineDuration(zeroGap, Duration.zero, 0),
          isNull,
        );
      });
    },
  );

  group('PlayerPositionLogic.clamp（进度换算，锁定原 _clampPosition 行为）', () {
    test('负值夹取为 0', () {
      expect(
        PlayerPositionLogic.clamp(
          const Duration(seconds: -1),
          const Duration(seconds: 100),
        ),
        Duration.zero,
      );
    });

    test('超出时长时夹取为时长', () {
      expect(
        PlayerPositionLogic.clamp(
          const Duration(seconds: 150),
          const Duration(seconds: 100),
        ),
        const Duration(seconds: 100),
      );
    });

    test('区间内原样返回', () {
      expect(
        PlayerPositionLogic.clamp(
          const Duration(seconds: 50),
          const Duration(seconds: 100),
        ),
        const Duration(seconds: 50),
      );
    });

    test('时长未知（0）时不做上界夹取', () {
      expect(
        PlayerPositionLogic.clamp(const Duration(seconds: 150), Duration.zero),
        const Duration(seconds: 150),
      );
      expect(
        PlayerPositionLogic.clamp(const Duration(seconds: 50), Duration.zero),
        const Duration(seconds: 50),
      );
    });
  });

  group(
    'PlayerQualityLogic.nextLowerQuality（智能音质降级档位，锁定原 _nextLowerQuality 行为）',
    () {
      test('无损 → 高品', () {
        expect(
          PlayerQualityLogic.nextLowerQuality(AudioQuality.lossless),
          AudioQuality.high,
        );
      });

      test('高品 → 标准', () {
        expect(
          PlayerQualityLogic.nextLowerQuality(AudioQuality.high),
          AudioQuality.standard,
        );
      });

      test('标准已最低档，返回 null', () {
        expect(
          PlayerQualityLogic.nextLowerQuality(AudioQuality.standard),
          isNull,
        );
      });
    },
  );

  group(
    'PlayerEqualizerLogic.levelsForBandCount（均衡器频段重采样，锁定原 _levelsForBandCount 行为）',
    () {
      test('目标频段数 <= 0 返回空列表', () {
        expect(
          PlayerEqualizerLogic.levelsForBandCount(const [0, 10], 0),
          isEmpty,
        );
        expect(
          PlayerEqualizerLogic.levelsForBandCount(const [0, 10], -3),
          isEmpty,
        );
      });

      test('频段数一致时返回内容相同的拷贝（非同一实例）', () {
        final source = [0, 10, 20];
        final result = PlayerEqualizerLogic.levelsForBandCount(source, 3);
        expect(result, source);
        expect(identical(result, source), isFalse);
        result[0] = 99;
        expect(source[0], 0, reason: '修改结果不应影响源列表');
      });

      test('单值源时填充为目标频段数', () {
        expect(PlayerEqualizerLogic.levelsForBandCount(const [7], 4), [
          7,
          7,
          7,
          7,
        ]);
      });

      test('多值源按最近邻重采样到目标频段数', () {
        // 与原实现同一公式：source[((i / (count-1)) * (source.length-1)).round()]
        expect(PlayerEqualizerLogic.levelsForBandCount(const [0, 10, 20], 5), [
          0,
          10,
          10,
          20,
          20,
        ]);
        expect(PlayerEqualizerLogic.levelsForBandCount(const [0, 100], 3), [
          0,
          100,
          100,
        ]);
      });
    },
  );

  group(
    'PlayerEqualizerLogic.restoreLevels（持久化均衡器等级恢复，锁定原 _restoreEqualizerLevels 行为）',
    () {
      final defaults = List<int>.filled(3, 0);

      test('null 或空字符串返回默认值拷贝', () {
        expect(PlayerEqualizerLogic.restoreLevels(null, defaults), [0, 0, 0]);
        expect(PlayerEqualizerLogic.restoreLevels('', defaults), [0, 0, 0]);
        final restored = PlayerEqualizerLogic.restoreLevels(null, defaults);
        expect(identical(restored, defaults), isFalse, reason: '必须返回拷贝');
      });

      test('非法 JSON 返回默认值', () {
        expect(PlayerEqualizerLogic.restoreLevels('not-json', defaults), [
          0,
          0,
          0,
        ]);
      });

      test('合法 JSON 但不是列表时返回默认值', () {
        expect(PlayerEqualizerLogic.restoreLevels('"abc"', defaults), [
          0,
          0,
          0,
        ]);
      });

      test('空列表视为无效，返回默认值', () {
        expect(PlayerEqualizerLogic.restoreLevels('[]', defaults), [0, 0, 0]);
      });

      test('数值四舍五入为整数', () {
        expect(PlayerEqualizerLogic.restoreLevels('[0, 1.4, 2.6]', defaults), [
          0,
          1,
          3,
        ]);
      });

      test('负数同样四舍五入（.5 远离零，与正数对称）', () {
        expect(
          PlayerEqualizerLogic.restoreLevels('[-1.4, -2.5, 2.5]', defaults),
          [-1, -3, 3],
        );
      });

      test('长度不一致时按频段数重采样', () {
        expect(PlayerEqualizerLogic.restoreLevels('[100, 200]', defaults), [
          100,
          200,
          200,
        ]);
      });
    },
  );

  group('PlayerLyricProgressLogic.forLine（桌面歌词逐字进度映射）', () {
    // 四个字各 500ms，但第二字后留出 2s 伴奏间隙（第三字 2.5s 才开始）。
    // 整行 4 个字符 → 每字占 1/4。
    const spaced = LyricLine(
      time: Duration.zero,
      text: '一二三四',
      words: [
        LyricWord(
          time: Duration.zero,
          duration: Duration(milliseconds: 500),
          text: '一',
        ),
        LyricWord(
          time: Duration(milliseconds: 500),
          duration: Duration(milliseconds: 500),
          text: '二',
        ),
        LyricWord(
          time: Duration(milliseconds: 2500),
          duration: Duration(milliseconds: 500),
          text: '三',
        ),
        LyricWord(
          time: Duration(milliseconds: 3000),
          duration: Duration(milliseconds: 500),
          text: '四',
        ),
      ],
    );

    test('字内线性推进', () {
      expect(
        PlayerLyricProgressLogic.forLine(
          line: spaced,
          position: const Duration(milliseconds: 250),
        ),
        closeTo(0.125, 1e-9),
      );
    });

    test('字间间隙停住不动（整行线性推进会在这里提前点亮）', () {
      // 间隙内任意时点的进度都应等于第二字结束处（2/4 = 0.5）。
      expect(
        PlayerLyricProgressLogic.forLine(
          line: spaced,
          position: const Duration(milliseconds: 1000),
        ),
        closeTo(0.5, 1e-9),
      );
      expect(
        PlayerLyricProgressLogic.forLine(
          line: spaced,
          position: const Duration(milliseconds: 2499),
        ),
        closeTo(0.5, 1e-9),
      );
    });

    test('末字结束后补齐为 1.0（不留半亮）', () {
      expect(
        PlayerLyricProgressLogic.forLine(
          line: spaced,
          position: const Duration(milliseconds: 3500),
        ),
        1.0,
      );
    });

    test('行首为 0 且全程单调不减', () {
      expect(
        PlayerLyricProgressLogic.forLine(line: spaced, position: Duration.zero),
        0.0,
      );
      var last = -1.0;
      for (var ms = 0; ms <= 3600; ms += 50) {
        final progress = PlayerLyricProgressLogic.forLine(
          line: spaced,
          position: Duration(milliseconds: ms),
        );
        expect(progress, greaterThanOrEqualTo(last));
        last = progress;
      }
      expect(last, 1.0);
    });

    test('无逐字时间时回退整行线性推进', () {
      const plain = LyricLine(
        time: Duration(seconds: 1),
        text: '一行歌词',
        duration: Duration(seconds: 4),
      );
      expect(
        PlayerLyricProgressLogic.forLine(
          line: plain,
          position: const Duration(seconds: 3),
        ),
        closeTo(0.5, 1e-9),
      );
    });

    test('无逐字时间且行时长不可得 → 1.0（历史语义：整行点亮）', () {
      const plain = LyricLine(time: Duration.zero, text: '一行歌词');
      expect(
        PlayerLyricProgressLogic.forLine(
          line: plain,
          position: const Duration(seconds: 9),
        ),
        1.0,
      );
    });
  });

  group('PlayerPlaybackLogic.shouldRestartTrackOnPlay（系统播放键曲末恢复判定）', () {
    test('非 completed 一律不重播（暂停中/播放中的系统播放键走普通续播）', () {
      expect(
        PlayerPlaybackLogic.shouldRestartTrackOnPlay(
          completed: false,
          duration: const Duration(seconds: 300),
          position: const Duration(seconds: 300),
        ),
        isFalse,
      );
      expect(
        PlayerPlaybackLogic.shouldRestartTrackOnPlay(
          completed: false,
          duration: null,
          position: Duration.zero,
        ),
        isFalse,
      );
    });

    test('completed 且位置停在尾部（含 250ms 容差）→ 重播回零', () {
      expect(
        PlayerPlaybackLogic.shouldRestartTrackOnPlay(
          completed: true,
          duration: const Duration(seconds: 300),
          position: const Duration(seconds: 300),
        ),
        isTrue,
      );
      expect(
        PlayerPlaybackLogic.shouldRestartTrackOnPlay(
          completed: true,
          duration: const Duration(seconds: 300),
          position: const Duration(seconds: 299, milliseconds: 800),
        ),
        isTrue,
      );
    });

    test('completed 但位置在容差之外 → 原地续播（seekToAndPlay 已定位曲中）', () {
      expect(
        PlayerPlaybackLogic.shouldRestartTrackOnPlay(
          completed: true,
          duration: const Duration(seconds: 300),
          position: const Duration(seconds: 299, milliseconds: 700),
        ),
        isFalse,
      );
      expect(
        PlayerPlaybackLogic.shouldRestartTrackOnPlay(
          completed: true,
          duration: const Duration(seconds: 300),
          position: const Duration(seconds: 42),
        ),
        isFalse,
      );
    });

    test('completed 但时长未知（<=0）→ 按重播处理（续播只会瞬间再 completed）', () {
      expect(
        PlayerPlaybackLogic.shouldRestartTrackOnPlay(
          completed: true,
          duration: null,
          position: Duration.zero,
        ),
        isTrue,
      );
      expect(
        PlayerPlaybackLogic.shouldRestartTrackOnPlay(
          completed: true,
          duration: Duration.zero,
          position: Duration.zero,
        ),
        isTrue,
      );
    });
  });

  group('PlayerPlaybackLogic.isTailStalled（曲末停滞 watchdog 判定）', () {
    test('控制器不在播（用户已暂停）→ 永不停滞，不误切', () {
      expect(
        PlayerPlaybackLogic.isTailStalled(
          ctrlPlaying: false,
          builtAt: const Duration(seconds: 299, milliseconds: 600),
          now: const Duration(seconds: 299, milliseconds: 600),
        ),
        isFalse,
      );
    });

    test('位置自基准起纹丝不动（±150ms 内）→ 停滞', () {
      expect(
        PlayerPlaybackLogic.isTailStalled(
          ctrlPlaying: true,
          builtAt: const Duration(seconds: 299, milliseconds: 600),
          now: const Duration(seconds: 299, milliseconds: 600),
        ),
        isTrue,
      );
      expect(
        PlayerPlaybackLogic.isTailStalled(
          ctrlPlaying: true,
          builtAt: const Duration(seconds: 299, milliseconds: 600),
          now: const Duration(seconds: 299, milliseconds: 700),
        ),
        isTrue,
      );
    });

    test('位置恢复了前进（超出容差）→ 不停滞', () {
      expect(
        PlayerPlaybackLogic.isTailStalled(
          ctrlPlaying: true,
          builtAt: const Duration(seconds: 299, milliseconds: 600),
          now: const Duration(seconds: 299, milliseconds: 800),
        ),
        isFalse,
      );
    });
  });
}
