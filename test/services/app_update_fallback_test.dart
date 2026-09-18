import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:shiyin_music/models/app_version.dart';
import 'package:shiyin_music/services/app_update_service.dart';

void main() {
  group('pickUpdateAssetUrl', () {
    final assets = <(String, String)>[
      ('shiyin-v2.5.2-impeller-arm64.apk', 'https://dl/impeller.apk'),
      ('shiyin-v2.5.2-skia-arm64.apk', 'https://dl/skia.apk'),
      ('shiyin-v2.5.2-windows-x64-portable.zip', 'https://dl/portable.zip'),
      ('shiyin-v2.5.2-windows-x64-setup.exe', 'https://dl/setup.exe'),
    ];

    test('Windows 便携版优先取 -portable.zip', () {
      expect(
        pickUpdateAssetUrl(assets, windowsAssetKind: kWindowsAssetPortable),
        'https://dl/portable.zip',
      );
    });

    test('Windows 安装版优先取 -setup.exe', () {
      expect(
        pickUpdateAssetUrl(assets, windowsAssetKind: kWindowsAssetSetup),
        'https://dl/setup.exe',
      );
    });

    test('Windows 无精确后缀时回退同扩展名', () {
      expect(
        pickUpdateAssetUrl(const [
          ('bundle.zip', 'https://dl/b.zip'),
          ('app.exe', 'https://dl/a.exe'),
        ], windowsAssetKind: kWindowsAssetPortable),
        'https://dl/b.zip',
      );
      expect(
        pickUpdateAssetUrl(const [
          ('bundle.zip', 'https://dl/b.zip'),
          ('app.exe', 'https://dl/a.exe'),
        ], windowsAssetKind: kWindowsAssetSetup),
        'https://dl/a.exe',
      );
    });

    test('Android 按渲染器选 apk，回退第一个 apk', () {
      expect(
        pickUpdateAssetUrl(assets, renderer: 'skia'),
        'https://dl/skia.apk',
      );
      expect(
        pickUpdateAssetUrl(assets, renderer: 'impeller'),
        'https://dl/impeller.apk',
      );
      // 老客户端行为：渲染器不认识时取第一个 apk（发版时 impeller 在前）。
      expect(
        pickUpdateAssetUrl(assets, renderer: 'unknown'),
        'https://dl/impeller.apk',
      );
    });

    test('Android 按渲染器 + ABI 精确选 apk（三变体 Release）', () {
      final triAssets = <(String, String)>[
        ('shiyin-v3.0.2-impeller-arm64.apk', 'https://dl/impeller-arm64.apk'),
        ('shiyin-v3.0.2-skia-arm64.apk', 'https://dl/skia-arm64.apk'),
        ('shiyin-v3.0.2-skia-arm32.apk', 'https://dl/skia-arm32.apk'),
      ];
      // 64 位默认变体。
      expect(
        pickUpdateAssetUrl(triAssets, renderer: 'impeller', abi: 'arm64'),
        'https://dl/impeller-arm64.apk',
      );
      // 64 位 skia：不得误吞 arm32 包（-arm64 与 -arm32 互不 contains）。
      expect(
        pickUpdateAssetUrl(triAssets, renderer: 'skia', abi: 'arm64'),
        'https://dl/skia-arm64.apk',
      );
      // 32 位老车机：必须拿到 arm32 包，拿到 arm64 包无法安装。
      expect(
        pickUpdateAssetUrl(triAssets, renderer: 'skia', abi: 'arm32'),
        'https://dl/skia-arm32.apk',
      );
    });

    test('Android 老 Release 无本 ABI 附件时逐级放宽', () {
      final legacyAssets = <(String, String)>[
        ('shiyin-v3.0.1-impeller-arm64.apk', 'https://dl/old-impeller.apk'),
        ('shiyin-v3.0.1-skia-arm64.apk', 'https://dl/old-skia.apk'),
      ];
      // v3.0.2 前只发过 arm64：32 位客户端按渲染器回退（历史上不存在
      // 32 位正式用户，可接受）。
      expect(
        pickUpdateAssetUrl(legacyAssets, renderer: 'skia', abi: 'arm32'),
        'https://dl/old-skia.apk',
      );
      // ABI 附件存在但渲染段缺失：按 ABI 匹配。
      expect(
        pickUpdateAssetUrl(const [
          ('shiyin-v9.0.0-arm32.apk', 'https://dl/arm32.apk'),
          ('shiyin-v9.0.0-arm64.apk', 'https://dl/arm64.apk'),
        ], renderer: 'skia', abi: 'arm32'),
        'https://dl/arm32.apk',
      );
    });

    test('无匹配返回空字符串', () {
      expect(pickUpdateAssetUrl(const [('a.dmg', 'https://dl/a.dmg')]), '');
    });
  });

  group('stripReleaseDownloadSection', () {
    test('截掉末尾「📥 下载」产物清单区，保留更新内容与完整变更链接', () {
      const body = '''
> 适用平台：全平台

## 更新内容

### ✨ 新功能

- **平板形态**：触屏侧栏重设计

---

**完整变更**：https://github.com/bamboostrip/shiyin-music/compare/v3.0.1...v3.0.2

## 📥 下载

每个产物均附带同名 `.sha256` 校验文件。

| 产物 | 说明 |
|------|------|
| `shiyin-v3.0.2-impeller-arm64.apk` | Android 64 位 · 默认渲染 |
| `shiyin-v3.0.2-skia-arm32.apk` | Android 32 位 · 老车机 |
''';
      final stripped = stripReleaseDownloadSection(body);
      expect(stripped, contains('平板形态'));
      expect(stripped, contains('完整变更'));
      expect(stripped, isNot(contains('📥')));
      expect(stripped, isNot(contains('.sha256')));
      expect(stripped, isNot(contains('impeller-arm64.apk')));
    });

    test('下载区后还有二级标题时只截到该标题为止', () {
      const body = '''
## 更新内容

- 修复 A

## 📥 下载

- 产物列表

## 后记

- 附言
''';
      final stripped = stripReleaseDownloadSection(body);
      expect(stripped, contains('修复 A'));
      expect(stripped, isNot(contains('产物列表')));
      expect(stripped, contains('后记'));
    });

    test('无下载区的老 Release 原样返回；正文普通「下载」文字不误伤', () {
      const body = '''
## 更新内容

- **下载重构**：并发下载更快
''';
      expect(stripReleaseDownloadSection(body), body.trim());
    });

    test('以「下载」开头的更新内容章节标题不误吞（格式契约精确匹配）', () {
      const body = '''
## 更新内容

### 下载管理重构

- 并发下载更快

## 📥 下载

- 产物清单
''';
      final stripped = stripReleaseDownloadSection(body);
      expect(stripped, contains('下载管理重构'));
      expect(stripped, contains('并发下载更快'));
      expect(stripped, isNot(contains('产物清单')));
    });
  });

  group('AppVersionInfo.fromGitHubRelease', () {
    Map<String, dynamic> release() => {
      'tag_name': 'v2.5.2',
      'body': '修复若干问题',
      'html_url':
          'https://github.com/bamboostrip/shiyin-music/releases/tag/v2.5.2',
      'assets': [
        {
          'name': 'shiyin-v2.5.2-windows-x64-portable.zip',
          'browser_download_url': 'https://dl/portable.zip',
        },
        {
          'name': 'shiyin-v2.5.2-windows-x64-setup.exe',
          'browser_download_url': 'https://dl/setup.exe',
        },
      ],
    };

    test('Windows 便携/安装按形态选附件', () {
      final portable = AppVersionInfo.fromGitHubRelease(
        release(),
        windowsAssetKind: kWindowsAssetPortable,
      );
      expect(portable.platform, 'windows');
      expect(portable.versionName, '2.5.2');
      expect(portable.downloadUrl, 'https://dl/portable.zip');

      final setup = AppVersionInfo.fromGitHubRelease(
        release(),
        windowsAssetKind: kWindowsAssetSetup,
      );
      expect(setup.downloadUrl, 'https://dl/setup.exe');
    });

    test('无附件时回退 Release 页面', () {
      final info = AppVersionInfo.fromGitHubRelease({
        'tag_name': 'v2.5.2',
        'html_url': 'https://gh/releases/tag/v2.5.2',
      }, windowsAssetKind: kWindowsAssetSetup);
      expect(info.downloadUrl, 'https://gh/releases/tag/v2.5.2');
      expect(info.hasDownloadUrl, isTrue);
    });
  });

  group('parseEntriesFromAtom', () {
    test('解析全部条目：链接取 tag，正文取 content', () {
      const feed = '''
<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <title>Release notes from shiyin-music</title>
  <entry>
    <id>tag:github.com,2008:Repository/1/v2.5.2</id>
    <link rel="alternate" type="text/html" href="https://github.com/bamboostrip/shiyin-music/releases/tag/v2.5.2"/>
    <title>v2.5.2</title>
    <content type="html">&lt;h2&gt;更新内容&lt;/h2&gt;&lt;ul&gt;&lt;li&gt;修复&lt;/li&gt;&lt;/ul&gt;</content>
  </entry>
  <entry>
    <link rel="alternate" type="text/html" href="https://github.com/bamboostrip/shiyin-music/releases/tag/v2.5.1"/>
    <title>v2.5.1</title>
    <content type="html">&lt;h2&gt;旧版本&lt;/h2&gt;</content>
  </entry>
</feed>
''';
      final entries = parseEntriesFromAtom(feed);
      expect(entries.length, 2);
      final (tag, link, content) = entries.first;
      expect(tag, 'v2.5.2');
      expect(
        link,
        'https://github.com/bamboostrip/shiyin-music/releases/tag/v2.5.2',
      );
      expect(
        content,
        '&lt;h2&gt;更新内容&lt;/h2&gt;&lt;ul&gt;&lt;li&gt;修复&lt;/li&gt;&lt;/ul&gt;',
      );
      expect(entries[1].$1, 'v2.5.1');
    });

    test('链接缺失时回退 title 取 tag（仅当 title 本身是合法正式版 tag）', () {
      const feed =
          '<feed><entry><title>v2.5.2</title>'
          '<content type="html">x</content></entry></feed>';
      final entries = parseEntriesFromAtom(feed);
      expect(entries.length, 1);
      expect(entries.first.$1, 'v2.5.2');
    });

    test('链接缺失且 title 是自由文本（非版本 tag）时不采用，跳过该条目', () {
      // Release 标题是发版者自由填写的文本：含中文/空格的标题直接当 tag
      // 会污染文件名与版本比较，必须跳过。
      const feed =
          '<feed><entry><title>v2.5.2 夏日版发布</title>'
          '<content type="html">x</content></entry>'
          '<entry><title>v2.5.1</title><content type="html">y</content>'
          '</entry></feed>';
      final entries = parseEntriesFromAtom(feed);
      expect(entries.length, 1);
      expect(entries.first.$1, 'v2.5.1');
    });

    test('预发布 tag 条目被跳过，返回不含该条', () {
      const feed =
          '<feed>'
          '<entry><link rel="alternate" type="text/html" '
          'href="https://github.com/a/b/releases/tag/v2.6.0-beta.1"/>'
          '<title>v2.6.0-beta.1</title><content type="html">beta</content>'
          '</entry>'
          '<entry><link rel="alternate" type="text/html" '
          'href="https://github.com/a/b/releases/tag/v2.5.2"/>'
          '<title>v2.5.2</title><content type="html">stable</content>'
          '</entry>'
          '</feed>';
      final entries = parseEntriesFromAtom(feed);
      expect(entries.length, 1);
      final (tag, link, content) = entries.first;
      expect(tag, 'v2.5.2');
      expect(link, 'https://github.com/a/b/releases/tag/v2.5.2');
      expect(content, 'stable');
    });

    test('空 feed（仓库无 Release）返回空列表', () {
      expect(parseEntriesFromAtom('<feed><title>x</title></feed>'), isEmpty);
    });
  });

  group('isStableVersionTag', () {
    test('正式版 tag 判定', () {
      expect(isStableVersionTag('v2.5.2'), isTrue);
      expect(isStableVersionTag('V2.5'), isTrue);
      expect(isStableVersionTag('2.5.2'), isTrue);
      expect(isStableVersionTag('2'), isTrue);
      expect(isStableVersionTag('v2.6.0-beta.1'), isFalse);
      expect(isStableVersionTag('v2.6.0-rc1'), isFalse);
      expect(isStableVersionTag('v2.5.2 发布'), isFalse);
      expect(isStableVersionTag(''), isFalse);
    });
  });

  group('unescapeHtml', () {
    test('常见命名与数字实体', () {
      expect(unescapeHtml('a &amp; b'), 'a & b');
      expect(unescapeHtml('&lt;h2&gt;x&lt;/h2&gt;'), '<h2>x</h2>');
      expect(unescapeHtml('&quot;q&quot; &#39;&#65;&#x42;'), '"q" \'AB');
      expect(unescapeHtml('&nbsp;'), ' ');
      // 未知实体原样保留
      expect(unescapeHtml('&unknown;'), '&unknown;');
    });
  });

  group('htmlReleaseBodyToMarkdown', () {
    test('标题/列表/加粗/行内码映射，悬空列表标记合并', () {
      // 模拟 Atom content 反转义后的真实结构（li 内容被 p 包裹）。
      const html =
          '<h2>更新内容</h2>\n<h3>Added</h3>\n<ul>\n<li>\n<p>'
          '<strong>深色模式</strong>：支持<code>三态切换</code>。</p>\n</li>\n</ul>';
      final text = htmlReleaseBodyToMarkdown(html);
      expect(text, contains('## 更新内容'));
      expect(text, contains('### Added'));
      expect(text, contains('- **深色模式**：支持`三态切换`。'));
    });

    test('纯文本原样保留（截首尾空白）', () {
      expect(htmlReleaseBodyToMarkdown('  暂无更新说明  '), '暂无更新说明');
    });

    test('连续空行压缩为最多一个', () {
      final text = htmlReleaseBodyToMarkdown('<p>a</p><div></div><p>b</p>');
      expect(text, 'a\n\nb');
    });
  });

  group('parseExpandedAssetLinks', () {
    test('提取 download 直链，忽略源码包并去重', () {
      const html = '''
<ul>
  <li><a href="/bamboostrip/shiyin-music/releases/download/v2.5.2/shiyin-v2.5.2-windows-x64-portable.zip"><span class="text-bold">portable.zip</span></a><span>28.5 MB</span></li>
  <li><a href="/bamboostrip/shiyin-music/releases/download/v2.5.2/shiyin-v2.5.2-windows-x64-setup.exe">setup.exe</a></li>
  <li><a href="/bamboostrip/shiyin-music/releases/download/v2.5.2/shiyin-v2.5.2-impeller-arm64.apk">apk</a></li>
  <li><a href="/bamboostrip/shiyin-music/archive/refs/tags/v2.5.2.zip">Source code (zip)</a></li>
</ul>
''';
      final assets = parseExpandedAssetLinks(html);
      expect(assets.length, 3);
      expect(assets[0], (
        'shiyin-v2.5.2-windows-x64-portable.zip',
        'https://github.com/bamboostrip/shiyin-music/releases/download/v2.5.2/shiyin-v2.5.2-windows-x64-portable.zip',
      ));
      expect(assets.any((a) => a.$1.endsWith('-setup.exe')), isTrue);
      expect(assets.any((a) => a.$1.endsWith('.apk')), isTrue);
      expect(assets.any((a) => a.$2.contains('/archive/')), isFalse);
    });

    test('选中后可按 Windows 规则复用', () {
      const html =
          '<a href="/o/r/releases/download/v2.5.2/shiyin-v2.5.2-windows-x64-setup.exe">x</a>';
      final picked = pickUpdateAssetUrl(
        parseExpandedAssetLinks(html),
        windowsAssetKind: kWindowsAssetSetup,
      );
      expect(picked, startsWith('https://github.com/o/r/releases/download/'));
      expect(picked, endsWith('-setup.exe'));
    });
  });

  group('extractTagFromLocation', () {
    test('从 302 Location 提取 tag', () {
      expect(
        extractTagFromLocation(
          'https://github.com/bamboostrip/shiyin-music/releases/tag/v2.5.2',
        ),
        'v2.5.2',
      );
      expect(
        extractTagFromLocation(
          'https://github.com/x/y/releases/tag/v1.2.3?foo=1',
        ),
        'v1.2.3',
      );
    });

    test('非 tag 重定向返回 null', () {
      expect(extractTagFromLocation('https://github.com/x/y/releases'), isNull);
      expect(extractTagFromLocation(''), isNull);
    });
  });

  group('detectWindowsInstalledBuild', () {
    test('同目录存在 flag 判为安装版', () async {
      final dir = await Directory.systemTemp.createTemp('shiyin_flag_test');
      addTearDown(() => dir.delete(recursive: true));
      final exe = File('${dir.path}${Platform.pathSeparator}ShiYinMusic.exe');
      await exe.writeAsBytes([0x4D, 0x5A]);

      expect(AppUpdateService.detectWindowsInstalledBuild(exe.path), isFalse);

      await File(
        '${dir.path}${Platform.pathSeparator}installed_by_inno.flag',
      ).writeAsString('installed');
      expect(AppUpdateService.detectWindowsInstalledBuild(exe.path), isTrue);
    });
  });

  group('AppUpdateService.isSupportedPlatform', () {
    test('Android / Windows 支持，其余平台不支持', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      expect(AppUpdateService.isSupportedPlatform, isTrue);

      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      expect(AppUpdateService.isSupportedPlatform, isFalse);

      debugDefaultTargetPlatformOverride = null;
    });
  });
}
