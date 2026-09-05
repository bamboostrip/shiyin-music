// 实网探针：验证检查更新的三级容灾解析逻辑对真实 GitHub 数据有效。
// 默认跳过（CI 无网络依赖）；手动运行：
//   flutter test test/services/app_update_live_probe_test.dart --dart-define=SHIYIN_LIVE_PROBE=true
@Timeout(Duration(minutes: 2))
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:shiyin_music/config/app_config.dart';
import 'package:shiyin_music/services/app_update_service.dart';

const _liveEnabled = bool.fromEnvironment(
  'SHIYIN_LIVE_PROBE',
  defaultValue: false,
);

void main() {
  final browserHeaders = const {
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
  };

  group('实网探针（github.com 域容灾端点）', () {
    test('Atom 订阅源解析 + expanded_assets 取直链 + 302 重定向探测', () async {
      // L2：Atom 订阅源
      final atomResp = await http
          .get(Uri.parse(AppConfig.githubReleasesAtomUrl), headers: browserHeaders)
          .timeout(const Duration(seconds: 15));
      expect(atomResp.statusCode, 200, reason: 'Atom 订阅源应可访问');
      final entry = parseLatestEntryFromAtom(atomResp.body);
      expect(entry, isNotNull, reason: '应解析出最新 Release 条目');
      final (tag, link, contentHtml) = entry!;
      expect(tag, startsWith('v'), reason: 'tag 应为 v 开头，实际：$tag');
      expect(link, contains('/releases/tag/'));
      final body = htmlReleaseBodyToMarkdown(unescapeHtml(contentHtml));
      expect(body.trim(), isNotEmpty, reason: '正文应非空');

      // L2 补充：expanded_assets 资产页
      final assetsResp = await http
          .get(
            Uri.parse(
              '${AppConfig.githubRepoUrl}/releases/expanded_assets/'
              '${Uri.encodeComponent(tag)}',
            ),
            headers: browserHeaders,
          )
          .timeout(const Duration(seconds: 15));
      expect(assetsResp.statusCode, 200);
      final assets = parseExpandedAssetLinks(assetsResp.body);
      expect(assets, isNotEmpty, reason: '应解析出附件直链');
      expect(
        assets.any((a) => a.$1.toLowerCase().endsWith('.apk')),
        isTrue,
        reason: '现有 Release 至少应含 Android APK 附件',
      );

      // L3：/releases/latest 302 重定向
      final probe = http.Request(
        'GET',
        Uri.parse(AppConfig.githubReleasesLatestPageUrl),
      )..followRedirects = false;
      final client = http.Client();
      String? location;
      try {
        final resp = await client.send(probe).timeout(
              const Duration(seconds: 15),
            );
        location = resp.headers['location'];
      } finally {
        client.close();
      }
      final redirectedTag = extractTagFromLocation(location ?? '');
      expect(redirectedTag, tag, reason: '重定向探测的 tag 应与 Atom 一致');

      // 直链可用性：Range 探测应 206/200
      final rangeResp = await http
          .get(
            Uri.parse(assets.first.$2),
            headers: {...browserHeaders, 'Range': 'bytes=0-0'},
          )
          .timeout(const Duration(seconds: 15));
      expect(
        rangeResp.statusCode == 206 || rangeResp.statusCode == 200,
        isTrue,
        reason: '附件直链应可请求，实际 ${rangeResp.statusCode}',
      );
    }, skip: !_liveEnabled);
  });
}
