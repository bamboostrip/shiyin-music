// 实网探针：验证检查更新的三级容灾解析逻辑对真实 GitHub 数据有效。
// 默认跳过（CI 无网络依赖）；手动运行：
//   flutter test test/services/app_update_live_probe_test.dart --dart-define=SHIYIN_LIVE_PROBE=true
@Timeout(Duration(minutes: 2))
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:shiyin_music/config/app_config.dart';
import 'package:shiyin_music/models/app_version.dart';
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
          .get(
            Uri.parse(AppConfig.githubReleasesAtomUrl),
            headers: browserHeaders,
          )
          .timeout(const Duration(seconds: 15));
      expect(atomResp.statusCode, 200, reason: 'Atom 订阅源应可访问');
      final entries = parseEntriesFromAtom(atomResp.body);
      expect(entries, isNotEmpty, reason: '应解析出最新 Release 条目');
      final (tag, link, contentHtml) = entries.first;
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
        final resp = await client
            .send(probe)
            .timeout(const Duration(seconds: 15));
        location = resp.headers['location'];
      } finally {
        client.close();
      }
      final redirectedTag = extractTagFromLocation(location ?? '');
      // /releases/latest 只指向最新正式版：Atom 第一条可能是纯正式格式
      // tag 的预发布（v3.0.22 实例），两者一致仅当仓库无未发正式版的新
      // 预发布。断言改为「重定向 tag = Atom 中不高于它的最新条目」。
      expect(redirectedTag, isNotNull, reason: '重定向应给出 tag');
      final redirectedVersion = stripVersionTagPrefix(redirectedTag!);
      final notAboveRedirect = entries
          .map((e) => e.$1)
          .where(
            (t) =>
                compareSemver(stripVersionTagPrefix(t), redirectedVersion) <=
                0,
          )
          .toList();
      expect(
        notAboveRedirect,
        isNotEmpty,
        reason: 'Atom 窗口内应有 ≤最新正式版的条目（窗口全预发布=窗口过窄，探针失效）',
      );
      expect(redirectedTag, notAboveRedirect.first,
          reason: '重定向 tag 应为 Atom 中 ≤它的最新条目（即最新正式版）');

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

    test('预发布排除：L1 标志位过滤 + L2 天花板过滤对真实仓库数据有效', () async {
      // L1：列表 API 响应里标志位为 prerelease/draft 的条目过滤后不得残留
      // （2026-11-20 修复动机：v3.0.22 是 prerelease:true 但 tag 为纯正式
      // 格式，语法层拦不住，曾被推给正式版用户）。
      final apiResp = await http
          .get(
            Uri.parse(AppConfig.githubReleasesListUrl),
            headers: {
              'User-Agent': AppConfig.githubUpdateUserAgent,
              'Accept': 'application/vnd.github+json',
            },
          )
          .timeout(const Duration(seconds: 15));
      if (apiResp.statusCode == 403 || apiResp.statusCode == 429) {
        // 未鉴权 API 60 次/时/IP，本机配额被消耗是常态：限流时跳过 L1 段
        // （L1 过滤逻辑由纯函数单测覆盖），继续验 L2 天花板段。
        // ignore: avoid_print
        print('[live-probe] API 限流（${apiResp.statusCode}），跳过 L1 段');
      } else {
        expect(apiResp.statusCode, 200, reason: 'Releases 列表 API 应可访问');
        final decoded = jsonDecode(apiResp.body);
        expect(decoded, isA<List<dynamic>>());
        final pairs = stableReleasesFromApi(decoded as List<dynamic>);
        expect(pairs, isNotEmpty, reason: '仓库应有正式版 Release');
        expect(
          pairs.any(
            (p) => p.$1['prerelease'] == true || p.$1['draft'] == true,
          ),
          isFalse,
          reason: '过滤结果不得含 prerelease/draft 条目',
        );
      }

      // L2：天花板 = /releases/latest 探测的最新正式版；Atom 条目过
      // 天花板过滤后不得高于它（当前仓库的 v3.0.22 预发布应被滤掉）。
      final atomResp = await http
          .get(
            Uri.parse(AppConfig.githubReleasesAtomUrl),
            headers: browserHeaders,
          )
          .timeout(const Duration(seconds: 15));
      expect(atomResp.statusCode, 200);
      final entries = parseEntriesFromAtom(atomResp.body);
      expect(entries, isNotEmpty);
      final probe = http.Request(
        'GET',
        Uri.parse(AppConfig.githubReleasesLatestPageUrl),
      )..followRedirects = false;
      final client = http.Client();
      String? location;
      try {
        final resp = await client
            .send(probe)
            .timeout(const Duration(seconds: 15));
        location = resp.headers['location'];
      } finally {
        client.close();
      }
      final ceilingTag = extractTagFromLocation(location ?? '');
      expect(ceilingTag, isNotNull, reason: '仓库应有正式版供 /releases/latest 指向');
      final ceilingVersion = stripVersionTagPrefix(ceilingTag!);
      final summaries = [
        for (final (tag, _, contentHtml) in entries)
          ReleaseEntrySummary(
            tag: tag,
            body: htmlReleaseBodyToMarkdown(unescapeHtml(contentHtml)),
          ),
      ];
      final stable = dropPrereleasesAboveCeiling(summaries, ceilingVersion);
      expect(
        stable.any((e) => compareSemver(e.versionName, ceilingVersion) > 0),
        isFalse,
        reason: '天花板过滤后不得有高于最新正式版的条目',
      );
      // 软断言：报告滤掉数量。仓库清空预发布后此探针不会空洞通过——
      // 数字直接暴露在输出里，人工跑探针时一眼可见过滤是否在工作。
      // ignore: avoid_print
      print(
        '[live-probe] Atom ${summaries.length} 条，天花板 $ceilingTag，'
        '滤掉高于天花板的预发布 ${summaries.length - stable.length} 条',
      );
    }, skip: !_liveEnabled);
  });
}
