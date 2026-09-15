// 平台相关性更新选版：Release notes「适用平台」标记解析（app_version.dart）
// 与最近若干 Release 的选版核心（app_update_service.dart）。
//
// 业务背景见 docs/release-process.md 的「版本适用平台标记」：发版永远是
// 全平台单 Release，标记只用于新版客户端过滤"与本平台无关"的更新提示。
import 'package:flutter_test/flutter_test.dart';

import 'package:shiyin_music/models/app_version.dart';
import 'package:shiyin_music/services/app_update_service.dart';

void main() {
  group('parseApplicablePlatforms', () {
    test('无标记 → null（含完全无关文本、空串）', () {
      expect(parseApplicablePlatforms('## 更新内容\n\n- 修复若干问题'), isNull);
      expect(parseApplicablePlatforms('本次更新修复了播放问题'), isNull);
      expect(parseApplicablePlatforms(''), isNull);
    });

    test('blockquote 全平台 → {all}（L1 原始 markdown 形态）', () {
      expect(parseApplicablePlatforms('> 适用平台：全平台\n\n## 更新内容'), {'all'});
    });

    test('裸文本形态（L2 转换后）Windows、Linux → {windows,linux}', () {
      expect(parseApplicablePlatforms('适用平台: Windows、Linux\n\n正文'), {
        'windows',
        'linux',
      });
    });

    test('同义词：PC / 桌面 / 桌面端 → {windows,linux}', () {
      expect(parseApplicablePlatforms('> 适用平台：PC'), {'windows', 'linux'});
      expect(parseApplicablePlatforms('> 适用平台：桌面'), {'windows', 'linux'});
      expect(parseApplicablePlatforms('> 适用平台：桌面端'), {'windows', 'linux'});
    });

    test('同义词：安卓 / 移动端 / 手机 → {android}', () {
      expect(parseApplicablePlatforms('> 适用平台：安卓'), {'android'});
      expect(parseApplicablePlatforms('> 适用平台：移动端'), {'android'});
      expect(parseApplicablePlatforms('> 适用平台：手机'), {'android'});
    });

    test('> 适用平台：Windows、Android → 两词', () {
      expect(parseApplicablePlatforms('> 适用平台：Windows、Android'), {
        'windows',
        'android',
      });
    });

    test('全未知词 → {all}（宁多提示不漏提示）', () {
      expect(parseApplicablePlatforms('> 适用平台：鸿蒙'), {'all'});
    });

    test('标记不在首行（正文中间出现）也能匹配', () {
      expect(parseApplicablePlatforms('## 更新内容\n\n> 适用平台：Linux\n\n- 修复'), {
        'linux',
      });
    });
  });

  group('releaseAffectsPlatform', () {
    test('null（无标记）→ 任何平台都影响（历史 Release 兜底）', () {
      expect(releaseAffectsPlatform(null, 'android'), isTrue);
      expect(releaseAffectsPlatform(null, 'windows'), isTrue);
      expect(releaseAffectsPlatform(null, 'linux'), isTrue);
    });

    test("{all} → 任何平台都影响", () {
      expect(releaseAffectsPlatform({'all'}, 'android'), isTrue);
      expect(releaseAffectsPlatform({'all'}, 'windows'), isTrue);
    });

    test("{windows,linux} 对 android 不影响、对 windows 影响", () {
      expect(releaseAffectsPlatform({'windows', 'linux'}, 'android'), isFalse);
      expect(releaseAffectsPlatform({'windows', 'linux'}, 'windows'), isTrue);
    });
  });

  group('selectRelevantUpdate', () {
    // 组合真实解析链：body → 标记 → 是否影响 Android。
    bool affectsAndroid(String body) =>
        releaseAffectsPlatform(parseApplicablePlatforms(body), 'android');

    test('全部条目 ≤ 当前 → null', () {
      final entries = [
        const ReleaseEntrySummary(tag: 'v3.0.1', body: '> 适用平台：全平台'),
        const ReleaseEntrySummary(tag: 'v3.0.0', body: '> 适用平台：Android'),
      ];
      expect(
        selectRelevantUpdate(
          entries,
          currentVersion: '3.0.1',
          platformAffected: affectsAndroid,
        ),
        isNull,
      );
    });

    test('新版本均仅 PC，页内可见 ≤当前 边界 → null（确定与本平台无关）', () {
      final entries = [
        const ReleaseEntrySummary(tag: 'v3.0.3', body: '> 适用平台：Windows、Linux'),
        const ReleaseEntrySummary(tag: 'v3.0.2', body: '> 适用平台：PC'),
        // 当前版本本身在页内，证明翻页窗口覆盖了版本边界。
        const ReleaseEntrySummary(tag: 'v3.0.1', body: '> 适用平台：全平台'),
      ];
      expect(
        selectRelevantUpdate(
          entries,
          currentVersion: '3.0.1',
          platformAffected: affectsAndroid,
        ),
        isNull,
      );
    });

    test('新版本中含影响本平台的条目 → newest 取最新、relevant 按版本升序', () {
      final entries = [
        const ReleaseEntrySummary(tag: 'v3.0.4', body: '> 适用平台：Windows、Linux'),
        const ReleaseEntrySummary(tag: 'v3.0.3', body: '> 适用平台：全平台'),
        const ReleaseEntrySummary(tag: 'v3.0.2', body: '> 适用平台：PC'),
      ];
      final selection = selectRelevantUpdate(
        entries,
        currentVersion: '3.0.1',
        platformAffected: affectsAndroid,
      )!;
      expect(selection.newest.tag, 'v3.0.4');
      expect(selection.relevant.map((e) => e.tag).toList(), ['v3.0.3']);
      expect(selection.conservativeFallback, isFalse);
    });

    test('无标记（历史 Release 形态）视为影响本平台', () {
      final entries = [
        const ReleaseEntrySummary(tag: 'v3.0.2', body: '修复若干问题'),
      ];
      final selection = selectRelevantUpdate(
        entries,
        currentVersion: '3.0.1',
        platformAffected: affectsAndroid,
      )!;
      expect(selection.newest.tag, 'v3.0.2');
      expect(selection.relevant.map((e) => e.tag).toList(), ['v3.0.2']);
    });

    test('保守边界：30 个连续仅 PC 条目全 >当前 且无边界 → 保守提示最新', () {
      final entries = [
        for (var i = 2; i <= 31; i++)
          ReleaseEntrySummary(tag: 'v3.0.$i', body: '> 适用平台：PC'),
      ];
      final selection = selectRelevantUpdate(
        entries,
        currentVersion: '3.0.1',
        platformAffected: affectsAndroid,
      )!;
      expect(selection.conservativeFallback, isTrue);
      expect(selection.newest.tag, 'v3.0.31');
      expect(selection.relevant.map((e) => e.tag).toList(), ['v3.0.31']);
    });

    test('乱序输入：newest 仍取 semver 最大者，relevant 仍按版本升序', () {
      final entries = [
        const ReleaseEntrySummary(tag: 'v3.0.2', body: '> 适用平台：全平台'),
        const ReleaseEntrySummary(tag: 'v3.0.4', body: '> 适用平台：全平台'),
        const ReleaseEntrySummary(tag: 'v3.0.3', body: '> 适用平台：全平台'),
      ];
      final selection = selectRelevantUpdate(
        entries,
        currentVersion: '3.0.1',
        platformAffected: affectsAndroid,
      )!;
      expect(selection.newest.tag, 'v3.0.4');
      expect(selection.relevant.map((e) => e.tag).toList(), [
        'v3.0.2',
        'v3.0.3',
        'v3.0.4',
      ]);
    });
  });
}
