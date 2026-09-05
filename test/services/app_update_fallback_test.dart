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
        pickUpdateAssetUrl(
          const [('bundle.zip', 'https://dl/b.zip'), ('app.exe', 'https://dl/a.exe')],
          windowsAssetKind: kWindowsAssetPortable,
        ),
        'https://dl/b.zip',
      );
      expect(
        pickUpdateAssetUrl(
          const [('bundle.zip', 'https://dl/b.zip'), ('app.exe', 'https://dl/a.exe')],
          windowsAssetKind: kWindowsAssetSetup,
        ),
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

    test('无匹配返回空字符串', () {
      expect(
        pickUpdateAssetUrl(const [('a.dmg', 'https://dl/a.dmg')]),
        '',
      );
    });
  });

  group('AppVersionInfo.fromGitHubRelease', () {
    Map<String, dynamic> release() => {
      'tag_name': 'v2.5.2',
      'body': '修复若干问题',
      'html_url': 'https://github.com/bamboostrip/shiyin-music/releases/tag/v2.5.2',
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
      final info = AppVersionInfo.fromGitHubRelease(
        {'tag_name': 'v2.5.2', 'html_url': 'https://gh/releases/tag/v2.5.2'},
        windowsAssetKind: kWindowsAssetSetup,
      );
      expect(info.downloadUrl, 'https://gh/releases/tag/v2.5.2');
      expect(info.hasDownloadUrl, isTrue);
    });
  });

  group('parseLatestEntryFromAtom', () {
    test('解析首个条目：链接取 tag，正文取 content', () {
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
      final entry = parseLatestEntryFromAtom(feed);
      expect(entry, isNotNull);
      final (tag, link, content) = entry!;
      expect(tag, 'v2.5.2');
      expect(link,
          'https://github.com/bamboostrip/shiyin-music/releases/tag/v2.5.2');
      expect(content, '&lt;h2&gt;更新内容&lt;/h2&gt;&lt;ul&gt;&lt;li&gt;修复&lt;/li&gt;&lt;/ul&gt;');
    });

    test('链接缺失时回退 title 取 tag', () {
      const feed = '<feed><entry><title>v2.5.2 发布</title>'
          '<content type="html">x</content></entry></feed>';
      final entry = parseLatestEntryFromAtom(feed);
      expect(entry?.$1, 'v2.5.2 发布');
    });

    test('空 feed（仓库无 Release）返回 null', () {
      expect(parseLatestEntryFromAtom('<feed><title>x</title></feed>'), isNull);
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
      const html = '<h2>更新内容</h2>\n<h3>Added</h3>\n<ul>\n<li>\n<p>'
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
      expect(
        assets[0],
        (
          'shiyin-v2.5.2-windows-x64-portable.zip',
          'https://github.com/bamboostrip/shiyin-music/releases/download/v2.5.2/shiyin-v2.5.2-windows-x64-portable.zip',
        ),
      );
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
        extractTagFromLocation('https://github.com/x/y/releases/tag/v1.2.3?foo=1'),
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
      final exe = File('${dir.path}${Platform.pathSeparator}ShiyinMusic.exe');
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
