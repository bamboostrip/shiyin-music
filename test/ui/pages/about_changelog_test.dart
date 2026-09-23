import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/ui/pages/about_page.dart';

/// 关于页更新日志只铺较新版本（见 ChangelogVersion.oldestShownVersion）：
/// update.md 保持全量历史，上屏时按 v2.4.0 截断。
void main() {
  const sample = '''
# 时音更新日志

## v3.0.7

> v3.0.6 因问题撤回未正式发布。

### 修复
- 最新一版的修复项

## v2.5.0

### 优化
- 中间版本

## v2.4.0
- 边界版本（含）

## v2.3.9
- 边界以下的第一个版本（不含）

## v2.3.0
- 更老的历史

## v1.0.0
- 最早的一版
''';

  group('ChangelogVersion.parseForAbout', () {
    test('只保留 v2.4.0 及更新的版本，且顺序沿用原文（新版本在前）', () {
      final versions = ChangelogVersion.parseForAbout(sample);

      expect(
        versions.map((v) => v.version).toList(),
        ['v3.0.7', 'v2.5.0', 'v2.4.0'],
      );
      // 条目仍然照常解析（截断不影响每版内容）。
      expect(versions.first.lines, contains('最新一版的修复项'));
    });

    test('边界严格：v2.3.9 被截掉、v2.4.0 保留', () {
      final kept = ChangelogVersion.parseForAbout(sample)
          .map((v) => v.version)
          .toList();

      expect(kept, contains('v2.4.0'));
      expect(kept, isNot(contains('v2.3.9')));
      expect(kept, isNot(contains('v1.0.0')));
    });

    test('版本号按段比较，不做字符串比较（v2.10.0 > v2.4.0）', () {
      final versions = ChangelogVersion.parseForAbout('''
## v2.10.0
- 十位小版本
## v2.4.0
- 边界
## v1.99.0
- 老版本
''');

      expect(versions.map((v) => v.version).toList(), ['v2.10.0', 'v2.4.0']);
    });

    test('全量解析不受影响（update.md 里仍保留全部历史）', () {
      final all = ChangelogVersion.parse(sample);

      expect(all.map((v) => v.version).toList(), [
        'v3.0.7',
        'v2.5.0',
        'v2.4.0',
        'v2.3.9',
        'v2.3.0',
        'v1.0.0',
      ]);
    });

    test('真实 update.md：截断后最老一版就是 v2.4.0，且少于全量', () {
      final content = File('update.md').readAsStringSync();

      final all = ChangelogVersion.parse(content);
      final shown = ChangelogVersion.parseForAbout(content);

      expect(shown, isNotEmpty);
      expect(shown.first.version, all.first.version);
      expect(shown.last.version, ChangelogVersion.oldestShownVersion);
      expect(shown.length, lessThan(all.length));
    });
  });
}
