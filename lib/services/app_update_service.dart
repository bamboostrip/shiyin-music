import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config/app_config.dart';
import '../models/app_version.dart';

/// 应用更新检查服务（数据源：GitHub Releases，无需后端）。
///
/// CI 打 `v*` tag 时会在 GitHub 发布带附件的 Release，本服务判断是否有新版本：
/// - Android：跳浏览器下载 APK；
/// - Windows 便携版：跳浏览器下载 zip，用户自行解压覆盖；
/// - Windows 安装版：应用内下载 setup.exe（进度 + 取消），退出并拉起安装向导。
///
/// 版本查询多级容灾（对齐 handwrite-sim 的 updater 策略，规避 api.github.com
/// 未鉴权 60 次/时/IP 的 403 风控）：
/// 1. GitHub REST API（信息最全）
/// 2. github.com 的 Releases Atom 订阅源 + expanded_assets 资产页（无 API 频控）
/// 3. github.com 的 /releases/latest 网页 302 重定向探测最新 tag（无频控）
class AppUpdateService {
  AppUpdateService();

  /// 应用内下载安装包用 HTTP 客户端（GitHub 下载会 302 到 CDN，dio 自动跟随）。
  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 60),
    ),
  );

  /// 记录上一次"自动检查"成功请求的时间戳（毫秒），用于节流。
  static const _lastAutoCheckKey = 'update.last_auto_check_ms';

  /// 抓取 github.com 网页端点（Atom / expanded_assets）时使用的浏览器 UA。
  static const _browserUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  /// 是否支持检查更新（非 Web 的 Android / Windows）。
  static bool get isSupportedPlatform {
    if (kIsWeb) {
      return false;
    }
    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.windows;
  }

  /// Windows 分发形态：exe 同目录存在 Inno 安装时写入的
  /// `installed_by_inno.flag` 即安装版，否则便携版。首次访问时判定一次并缓存。
  static final bool isWindowsInstalledBuild = detectWindowsInstalledBuild(
    Platform.resolvedExecutable,
  );

  /// 判定 [exePath] 所在目录是否为 Inno Setup 安装形态（供测试注入路径）。
  @visibleForTesting
  static bool detectWindowsInstalledBuild(String exePath) {
    try {
      final dir = File(exePath).parent;
      return File(
        '${dir.path}${Platform.pathSeparator}installed_by_inno.flag',
      ).existsSync();
    } catch (_) {
      return false;
    }
  }

  /// 当前构建在附件选择时使用的平台参数。
  String get _rendererForAsset => _isAndroid ? AppConfig.renderer : '';

  /// 当前构建的 Windows 形态附件参数（非 Windows 返回 ''）。
  String get _windowsAssetKind {
    if (!_isWindows) {
      return '';
    }
    return isWindowsInstalledBuild ? kWindowsAssetSetup : kWindowsAssetPortable;
  }

  bool get _isWindows =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// 检查更新。
  ///
  /// - [manual] 为 true（About 页手动点击）时每次都真正请求，且错误向上抛由 UI 提示；
  /// - [manual] 为 false（启动自动检查）时受 [AppConfig.updateAutoCheckInterval] 节流，
  ///   且仅返回"是否有更新"，错误由调用方静默处理。
  ///
  /// 返回非 null 表示存在比当前版本更新的 Release。
  Future<AppVersionInfo?> checkForUpdate({bool manual = false}) async {
    if (!isSupportedPlatform) {
      return null;
    }

    if (!manual) {
      final prefs = await SharedPreferences.getInstance();
      final last = prefs.getInt(_lastAutoCheckKey) ?? 0;
      final elapsed = DateTime.now().millisecondsSinceEpoch - last;
      if (elapsed < AppConfig.updateAutoCheckInterval.inMilliseconds) {
        return null;
      }
    }

    // 抛出的异常：手动检查由 UI 捕获并提示；自动检查由调用方静默吞掉。
    final latest = await _fetchLatestFromGitHub();

    // 仅在成功请求后记录节流时间戳（失败不记录，下次启动可重试）。
    if (!manual) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(
        _lastAutoCheckKey,
        DateTime.now().millisecondsSinceEpoch,
      );
    }

    if (compareSemver(latest.versionName, AppConfig.appVersion) <= 0) {
      return null;
    }
    return latest;
  }

  /// 多级容灾获取最新 Release：API → Atom 订阅源 → 网页重定向。
  ///
  /// 任一级"暂无发布版本"（仓库确实没有 Release）直接抛出不降级；
  /// 其余失败（含网络超时、连接异常等非 StateError 错误）逐级降级，
  /// 全部失败时聚合报错（限流时给出友好文案）。
  Future<AppVersionInfo> _fetchLatestFromGitHub() async {
    final errors = <String>[];
    var sawRateLimit = false;

    try {
      return await _fetchViaApi();
    } on StateError catch (error) {
      if (error.message.contains('暂无发布版本')) rethrow;
      if (error.message.contains('限流')) sawRateLimit = true;
      errors.add(error.message);
    } catch (error) {
      errors.add('$error');
    }

    try {
      return await _fetchViaAtomFeed();
    } on StateError catch (error) {
      if (error.message.contains('暂无发布版本')) rethrow;
      errors.add(error.message);
    } catch (error) {
      errors.add('$error');
    }

    try {
      return await _fetchViaRedirect();
    } on StateError catch (error) {
      if (error.message.contains('暂无发布版本')) rethrow;
      errors.add(error.message);
    } catch (error) {
      errors.add('$error');
    }

    if (sawRateLimit) {
      throw StateError('检查频繁触发 GitHub 限流，请稍后再试');
    }
    throw StateError('请求 GitHub 失败（${errors.join('；')}）');
  }

  /// L1：GitHub REST API（信息最全，但受 60 次/时/IP 限制）。
  Future<AppVersionInfo> _fetchViaApi() async {
    final response = await http
        .get(
          Uri.parse(AppConfig.githubReleasesLatestUrl),
          headers: const {
            'User-Agent': AppConfig.githubUpdateUserAgent,
            'Accept': 'application/vnd.github+json',
          },
        )
        .timeout(const Duration(seconds: 15));

    if (response.statusCode == 404) {
      throw StateError('暂无发布版本');
    }
    if (response.statusCode == 403 || response.statusCode == 429) {
      throw StateError('GitHub 接口限流（${response.statusCode}）');
    }
    if (response.statusCode != 200) {
      throw StateError('请求 GitHub 失败（${response.statusCode}）');
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw StateError('GitHub 返回数据格式异常');
    }
    return AppVersionInfo.fromGitHubRelease(
      decoded,
      renderer: _rendererForAsset,
      windowsAssetKind: _windowsAssetKind,
    );
  }

  /// L2：Releases Atom 订阅源取版本与正文，expanded_assets 补附件直链
  /// （都在 github.com 域，不占 API 频次）。
  Future<AppVersionInfo> _fetchViaAtomFeed() async {
    final xml = await _getText(Uri.parse(AppConfig.githubReleasesAtomUrl));
    final entry = parseLatestEntryFromAtom(xml);
    if (entry == null) {
      // 仓库从未发布过 Release 时 Atom 为空 feed，语义与 API 404 一致。
      throw StateError('暂无发布版本');
    }
    final (tag, releasePage, contentHtml) = entry;
    return _assembleFromTag(
      tag: tag,
      releasePageOverride: releasePage,
      updateContent: htmlReleaseBodyToMarkdown(unescapeHtml(contentHtml)),
    );
  }

  /// L3：/releases/latest 网页 302 重定向探测最新 tag，再走 expanded_assets
  /// 补附件直链（此路径拿不到正文，提示用户前往发布页查看）。
  Future<AppVersionInfo> _fetchViaRedirect() async {
    final request = http.Request(
      'GET',
      Uri.parse(AppConfig.githubReleasesLatestPageUrl),
    )..followRedirects = false;

    final client = http.Client();
    try {
      final response = await client
          .send(request)
          .timeout(const Duration(seconds: 10));
      if (response.statusCode == 404) {
        throw StateError('暂无发布版本');
      }
      final tag = extractTagFromLocation(
        response.headers['location'] ?? '',
      );
      if (tag == null) {
        throw StateError('重定向探测失败（${response.statusCode}）');
      }
      return _assembleFromTag(
        tag: tag,
        updateContent: '更新说明获取失败，请前往发布页查看。',
      );
    } finally {
      client.close();
    }
  }

  /// 由 tag 组装 [AppVersionInfo]（L2/L3 共用），附件直链尽力从
  /// expanded_assets 资产页补全。
  Future<AppVersionInfo> _assembleFromTag({
    required String tag,
    required String updateContent,
    String releasePageOverride = '',
  }) async {
    final versionName = stripVersionTagPrefix(tag);
    final releasePage = releasePageOverride.isNotEmpty
        ? releasePageOverride
        : '${AppConfig.githubRepoUrl}/releases/tag/$tag';
    final assets = await _tryFetchExpandedAssets(tag);
    final picked = pickUpdateAssetUrl(
      assets,
      renderer: _rendererForAsset,
      windowsAssetKind: _windowsAssetKind,
    );

    return AppVersionInfo(
      platform: _isWindows
          ? AppUpdatePlatform.windows.apiValue
          : AppUpdatePlatform.android.apiValue,
      versionName: versionName.isEmpty ? tag : versionName,
      versionCode: semverToCode(versionName),
      updateContent: updateContent,
      downloadUrl: picked.isNotEmpty ? picked : releasePage,
      forceUpdate: false,
    );
  }

  /// 请求 github.com 网页端点（浏览器 UA，非 API 域）。
  Future<String> _getText(
    Uri uri, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final response = await http
        .get(uri, headers: const {'User-Agent': _browserUserAgent})
        .timeout(timeout);
    if (response.statusCode != 200) {
      throw StateError('请求 GitHub 失败（${response.statusCode}）');
    }
    return response.body;
  }

  /// 抓取 expanded_assets 资产页解析附件直链；失败不影响版本判断（尽力而为）。
  Future<List<(String, String)>> _tryFetchExpandedAssets(String tag) async {
    try {
      final html = await _getText(
        Uri.parse(
          '${AppConfig.githubRepoUrl}/releases/expanded_assets/'
          '${Uri.encodeComponent(tag)}',
        ),
      );
      return parseExpandedAssetLinks(html);
    } catch (_) {
      return const [];
    }
  }

  /// 在外部浏览器打开更新包链接（直链附件，或回退的 Release 页面）。
  ///
  /// Android / Windows 便携版的主路径，也是 Windows 安装版"浏览器下载"入口。
  Future<void> downloadAndInstall(AppVersionInfo version) async {
    if (!version.hasDownloadUrl) {
      throw StateError('更新包下载地址为空');
    }

    final uri = Uri.tryParse(version.downloadUrl);
    if (uri == null) {
      throw StateError('更新包下载地址无效');
    }

    final success = await launchUrl(
      uri,
      mode: LaunchMode.externalApplication,
    );
    if (!success) {
      throw StateError('无法在浏览器中打开下载链接');
    }
  }

  /// 应用内下载 Windows 安装包到系统"下载"目录，返回本地文件路径。
  ///
  /// 进度经 [onProgress]（累计已收 / 总字节）回调；[cancelToken] 取消后
  /// 残留的部分文件会被清理。完成后校验文件大小大于 0。
  Future<String> downloadWindowsSetup(
    AppVersionInfo version, {
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final url = version.downloadUrl;
    final uri = Uri.tryParse(url);
    if (uri == null || !url.toLowerCase().endsWith('.exe')) {
      throw StateError('安装包下载地址无效（未找到 setup.exe 附件）');
    }

    final downloadsDir =
        await getDownloadsDirectory() ?? await getTemporaryDirectory();
    final destPath =
        '${downloadsDir.path}${Platform.pathSeparator}'
        'ShiyinMusic-Setup-v${version.versionName}.exe';

    try {
      await _dio.download(
        uri.toString(),
        destPath,
        cancelToken: cancelToken,
        options: Options(
          headers: const {'User-Agent': AppConfig.githubUpdateUserAgent},
        ),
        onReceiveProgress: onProgress,
      );
    } catch (error) {
      // 取消/中断时清掉写了一半的文件，避免下次误装损坏包。
      final file = File(destPath);
      if (await file.exists()) {
        try {
          await file.delete();
        } catch (_) {}
      }
      if (error is DioException && error.type == DioExceptionType.cancel) {
        throw StateError('已取消下载');
      }
      rethrow;
    }

    final file = File(destPath);
    if (!await file.exists() || await file.length() <= 0) {
      throw StateError('安装包下载不完整');
    }
    return destPath;
  }

  /// 拉起安装向导并退出本应用（Windows 安装版"退出并安装"）。
  ///
  /// detached 启动使向导独立于本进程存活；`exit(0)` 立即终止进程，
  /// 音频设备、悬浮歌词窗、下载句柄随进程一并释放，避免安装器报文件占用
  /// （Inno 侧 `CloseApplications=yes` 再兜底其他残留副本）。
  Future<void> launchWindowsInstallerAndExit(String setupPath) async {
    final file = File(setupPath);
    if (!await file.exists()) {
      throw StateError('安装包不存在：$setupPath');
    }
    await Process.start(setupPath, [], mode: ProcessStartMode.detached);
    exit(0);
  }
}

/// 解析 Atom 订阅源的第一个（最新的）Release 条目。
///
/// 返回 `(tag, release 页链接, 转义状态的正文 HTML)`：tag 优先取
/// `href="…/releases/tag/<tag>"` 链接，回退 `<title>`；正文取
/// `<content type="html">`。解析不出返回 null。
@visibleForTesting
(String, String, String)? parseLatestEntryFromAtom(String feedXml) {
  final entryStart = feedXml.indexOf('<entry>');
  if (entryStart < 0) {
    return null;
  }
  final entryEndRel = feedXml.indexOf('</entry>', entryStart);
  final entryEnd = entryEndRel < 0 ? feedXml.length : entryEndRel;
  final entry = feedXml.substring(entryStart, entryEnd);

  var tag = '';
  var link = '';
  final linkMatch = RegExp(
    r'href="([^"]+/releases/tag/([^"]+))"',
  ).firstMatch(entry);
  if (linkMatch != null) {
    tag = unescapeHtml(linkMatch.group(2) ?? '');
    link = unescapeHtml(linkMatch.group(1) ?? '');
  }
  if (tag.isEmpty) {
    final titleMatch = RegExp('<title>([^<]+)</title>').firstMatch(entry);
    if (titleMatch == null) {
      return null;
    }
    tag = titleMatch.group(1)?.trim() ?? '';
  }
  if (tag.isEmpty) {
    return null;
  }

  final contentMatch = RegExp(
    r'<content[^>]*>([\s\S]*?)</content>',
  ).firstMatch(entry);
  final content = contentMatch?.group(1) ?? '';

  return (tag, link, content);
}

/// 反转义常见 HTML 实体（`&amp;` `&lt;` `&gt;` `&quot;` `&#39;` `&nbsp;`
/// 及十/十六进制数字实体）；未知实体原样保留。
@visibleForTesting
String unescapeHtml(String input) {
  return input.replaceAllMapped(
    RegExp(r'&(#[xX]?[0-9A-Fa-f]+|[a-zA-Z][a-zA-Z0-9]*);'),
    (match) {
      final entity = match.group(1)!;
      switch (entity) {
        case 'amp':
          return '&';
        case 'lt':
          return '<';
        case 'gt':
          return '>';
        case 'quot':
          return '"';
        case 'apos':
          return "'";
        case 'nbsp':
          return ' ';
      }
      if (entity.startsWith('#')) {
        final hex = entity.startsWith('#x') || entity.startsWith('#X');
        final code = int.tryParse(
          entity.substring(hex ? 2 : 1),
          radix: hex ? 16 : 10,
        );
        if (code != null) {
          return String.fromCharCode(code);
        }
      }
      // 未知实体原样保留。
      return match.group(0)!;
    },
  );
}

/// 把 Atom `<content>` 中转义后的 Release 正文 HTML 转为可读的伪 Markdown：
/// h2/h3/h4 映射为 `##` 标题、li 映射为 `- `、code 映射为反引号、
/// strong/b 映射为 `**`，其余标签剥离并按块级元素换行。
@visibleForTesting
String htmlReleaseBodyToMarkdown(String html) {
  String replacementFor(String name, bool isClose) {
    // 开标签专属映射（标题/列表只看开标签，配对闭标签输出空串）。
    if (!isClose) {
      switch (name) {
        case 'h2':
          return '\n\n## ';
        case 'h3':
          return '\n\n### ';
        case 'h4':
          return '\n\n#### ';
        case 'li':
          return '\n- ';
      }
    }
    // 开闭标签同形的映射。
    return switch (name) {
      'strong' || 'b' => '**',
      'code' => '`',
      'br' => '\n',
      'p' || 'div' || 'ul' || 'ol' || 'table' || 'tr' || 'blockquote' ||
      'pre' || 'section' => '\n',
      _ => '',
    };
  }

  final out = StringBuffer();
  final tagPattern = RegExp(r'<(/?)([a-zA-Z0-9]+)[^>]*>');
  var rest = html;
  while (true) {
    final match = tagPattern.firstMatch(rest);
    if (match == null) {
      out.write(rest);
      break;
    }
    out.write(rest.substring(0, match.start));
    out.write(
      replacementFor((match.group(2) ?? '').toLowerCase(), match.group(1) == '/'),
    );
    rest = rest.substring(match.end);
  }

  var text = out.toString();
  // GitHub 会把 <li> 内容包进 <p>，标签转换后 "- " 标记与内容被换行拆开，
  // 先把悬空标记行与其后内容（含多个空行）合并，再压缩连续空行。
  text = text.replaceAll(RegExp(r'\n[ \t]*-[ \t]*\n+'), '\n- ');
  text = text.replaceAll(RegExp(r'\n{3,}'), '\n\n');
  return text.trim();
}

/// 解析 expanded_assets 资产页 HTML，提取附件 `(文件名, 直链)` 列表：
/// 取 `href="/<owner>/<repo>/releases/download/<tag>/<文件名>"` 形式的链接，
/// 忽略源码包（/archive/）与重复项。
@visibleForTesting
List<(String, String)> parseExpandedAssetLinks(String html) {
  final assets = <(String, String)>[];
  final pattern = RegExp(r'href="(/[^"]+/releases/download/[^"]+)"');
  for (final match in pattern.allMatches(html)) {
    final path = match.group(1)!;
    if (path.contains('/archive/')) {
      continue;
    }
    final name = path.substring(path.lastIndexOf('/') + 1);
    if (name.isEmpty) {
      continue;
    }
    final lower = name.toLowerCase();
    if (!lower.endsWith('.zip') && !lower.endsWith('.exe') && !lower.endsWith(
      '.apk',
    )) {
      continue;
    }
    if (assets.any((asset) => asset.$1 == name)) {
      continue;
    }
    assets.add((name, 'https://github.com$path'));
  }
  return assets;
}

/// 从 /releases/latest 的 302 Location（`…/releases/tag/vX.Y.Z…`）提取 tag。
@visibleForTesting
String? extractTagFromLocation(String location) {
  final marker = '/releases/tag/';
  final index = location.indexOf(marker);
  if (index < 0) {
    return null;
  }
  final tail = location.substring(index + marker.length);
  final tag = tail.split(RegExp(r'[/?#]')).first;
  return tag.isEmpty ? null : tag;
}
