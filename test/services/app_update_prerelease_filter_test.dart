import 'package:flutter_test/flutter_test.dart';

import 'package:shiyin_music/services/app_update_service.dart';

void main() {
  /// 手工构造一条 Releases 列表 API 响应条目（字段缺失即不写该键）。
  Map<String, dynamic> release({
    String tag = 'v3.0.22',
    bool? prerelease,
    bool? draft,
    String body = '',
  }) {
    return {
      'tag_name': tag,
      'body': body,
      'prerelease': ?prerelease,
      'draft': ?draft,
    };
  }

  group('stableReleasesFromApi', () {
    test('纯正式格式 tag 的 prerelease 被跳过（v3.0.22 实例）', () {
      final pairs = stableReleasesFromApi([
        release(tag: 'v3.0.22', prerelease: true),
        release(tag: 'v3.0.21'),
      ]);
      expect(pairs.map((p) => p.$2.tag), ['v3.0.21']);
    });

    test('draft 条目被跳过', () {
      final pairs = stableReleasesFromApi([
        release(tag: 'v3.1.0', draft: true),
        release(tag: 'v3.0.21'),
      ]);
      expect(pairs.map((p) => p.$2.tag), ['v3.0.21']);
    });

    test('带 -beta 后缀的 tag 被语法层跳过（既有语义不变）', () {
      final pairs = stableReleasesFromApi([
        release(tag: 'v2.6.0-beta.1', prerelease: true),
        release(tag: 'v3.0.21'),
      ]);
      expect(pairs.map((p) => p.$2.tag), ['v3.0.21']);
    });

    test('无标志位与显式 false 的正式版都保留', () {
      final pairs = stableReleasesFromApi([
        release(tag: 'v3.0.22'),
        release(tag: 'v3.0.21', prerelease: false, draft: false),
      ]);
      expect(pairs.map((p) => p.$2.tag), ['v3.0.22', 'v3.0.21']);
    });

    test('prerelease/draft 字段缺失时交给语法层兜底（保守不误杀）', () {
      final pairs = stableReleasesFromApi([
        release(tag: 'v3.0.21'),
      ]);
      expect(pairs.map((p) => p.$2.tag), ['v3.0.21']);
    });

    test('非 map / 空 tag / 非法 tag 语法跳过', () {
      final pairs = stableReleasesFromApi(<dynamic>[
        'not-a-map',
        release(tag: ''),
        release(tag: 'v2.5.2 发布'),
      ]);
      expect(pairs, isEmpty);
    });

    test('返回对保留原始 JSON 与摘要正文', () {
      final json = release(
        tag: 'v3.0.21',
        body: '## 适用平台\n\n- android',
      );
      final pairs = stableReleasesFromApi([json]);
      expect(pairs, hasLength(1));
      expect(identical(pairs.single.$1, json), isTrue);
      expect(pairs.single.$2.body, json['body']);
      expect(pairs.single.$2.versionName, '3.0.21');
    });
  });

  group('dropPrereleasesAboveCeiling', () {
    ReleaseEntrySummary entry(String tag) =>
        ReleaseEntrySummary(tag: tag, body: '');

    test('高于天花板的纯正式 tag 条目被丢弃（v3.0.22 场景）', () {
      final stable = dropPrereleasesAboveCeiling(
        [entry('v3.0.22'), entry('v3.0.21'), entry('v3.0.20')],
        '3.0.21',
      );
      expect(stable.map((e) => e.tag), ['v3.0.21', 'v3.0.20']);
    });

    test('等于天花板的条目保留', () {
      final stable = dropPrereleasesAboveCeiling(
        [entry('v3.0.21')],
        '3.0.21',
      );
      expect(stable.map((e) => e.tag), ['v3.0.21']);
    });

    test('全部高于天花板 → 空列表', () {
      final stable = dropPrereleasesAboveCeiling(
        [entry('v3.0.22'), entry('v3.1.0')],
        '3.0.21',
      );
      expect(stable, isEmpty);
    });
  });
}
