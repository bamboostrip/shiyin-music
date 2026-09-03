import '../config/app_config.dart';
import 'music_models.dart';

enum AppUpdatePlatform {
  android('android'),
  ios('ios'),
  hm('hm');

  const AppUpdatePlatform(this.apiValue);

  final String apiValue;
}

class AppVersionInfo {
  const AppVersionInfo({
    required this.platform,
    required this.versionName,
    required this.versionCode,
    required this.updateContent,
    required this.downloadUrl,
    required this.forceUpdate,
    this.releaseDate,
  });

  final String platform;
  final String versionName;
  final int versionCode;
  final String updateContent;
  final String downloadUrl;
  final bool forceUpdate;
  final DateTime? releaseDate;

  bool get hasDownloadUrl => downloadUrl.trim().isNotEmpty;

  bool get isNewerThanCurrent {
    final currentCode = normalizedVersionCode(AppConfig.appVersionCode);
    return versionCode > currentCode;
  }

  factory AppVersionInfo.fromJson(Map<String, dynamic> json) {
    return AppVersionInfo(
      platform: asString(json['platform']) ?? '',
      versionName: asString(json['versionName']) ?? '',
      versionCode: normalizedVersionCode(json['versionCode']),
      updateContent: asString(json['updateContent']) ?? '',
      downloadUrl: asString(json['downloadUrl']) ?? '',
      forceUpdate: _asBool(json['forceUpdate']),
      releaseDate: DateTime.tryParse(asString(json['releaseDate']) ?? ''),
    );
  }

  /// 从 GitHub Releases API（`/releases/latest`）的 JSON 构造。
  ///
  /// - `tag_name`（去掉前导 `v`）作为 [versionName]
  /// - `body` 作为更新说明 [updateContent]
  /// - 附件选择：[renderer] 非空时优先取文件名含 `-$renderer` 的 `.apk`
  ///  （如 `shiyin-v2.5.1-skia-arm64.apk`），保证 Skia 机下 Skia 包、
  ///   Impeller 机下 Impeller 包；找不到或 [renderer] 为空时回退到
  ///   第一个 `.apk`（兼容双包之前的老 Release；发版时把 impeller 包
  ///   放前面，老版本客户端行为不变）。没有附件时回退到 release 页面 [htmlUrl]
  /// - GitHub 不提供"强制更新"，故 [forceUpdate] 恒为 false
  factory AppVersionInfo.fromGitHubRelease(
    Map<String, dynamic> json, {
    String htmlUrl = '',
    String renderer = '',
  }) {
    final rawTag = asString(json['tag_name']) ?? '';
    final versionName = stripVersionTagPrefix(rawTag);

    var downloadUrl = '';
    var fallbackUrl = '';
    final assets = json['assets'];
    if (assets is List) {
      final want = renderer.trim().toLowerCase();
      for (final asset in assets) {
        if (asset is! Map) continue;
        final name = asString(asset['name']) ?? '';
        if (!name.toLowerCase().endsWith('.apk')) continue;
        final url = asString(asset['browser_download_url']) ?? '';
        if (url.isEmpty) continue;
        if (fallbackUrl.isEmpty) fallbackUrl = url;
        if (want.isNotEmpty && name.toLowerCase().contains('-$want')) {
          downloadUrl = url;
          break;
        }
      }
    }
    downloadUrl = downloadUrl.isEmpty ? fallbackUrl : downloadUrl;
    final releasePageUrl = asString(json['html_url']) ?? htmlUrl;
    if (downloadUrl.isEmpty) {
      downloadUrl = releasePageUrl;
    }

    return AppVersionInfo(
      platform: AppUpdatePlatform.android.apiValue,
      versionName: versionName.isEmpty ? rawTag : versionName,
      versionCode: semverToCode(versionName),
      updateContent: asString(json['body']) ?? '',
      downloadUrl: downloadUrl,
      forceUpdate: false,
      releaseDate: DateTime.tryParse(asString(json['published_at']) ?? ''),
    );
  }
}

/// 去掉版本 tag 的前导 `v`/`V` 与首尾空白，例如 `v2.4.0` → `2.4.0`。
String stripVersionTagPrefix(String tag) {
  var t = tag.trim();
  if (t.length > 1 && (t.startsWith('v') || t.startsWith('V'))) {
    t = t.substring(1);
  }
  return t;
}

/// 取语义化版本的前三段整数（不足补 0，忽略预发布/构建号）。
List<int> _semverParts(String version) {
  final core = stripVersionTagPrefix(version).split('-').first.split('+').first;
  final segs = core.split('.');
  int at(int i) => i < segs.length ? (int.tryParse(segs[i]) ?? 0) : 0;
  return [at(0), at(1), at(2)];
}

/// 语义化版本比较：`a<b` → -1，相等 → 0，`a>b` → 1。
int compareSemver(String a, String b) {
  final pa = _semverParts(a);
  final pb = _semverParts(b);
  for (var i = 0; i < 3; i++) {
    if (pa[i] != pb[i]) return pa[i] < pb[i] ? -1 : 1;
  }
  return 0;
}

/// 由语义化版本生成一个单调的整数 code（major*10000 + minor*100 + patch）。
int semverToCode(String version) {
  final p = _semverParts(version);
  return p[0] * 10000 + p[1] * 100 + p[2];
}

int normalizedVersionCode(Object? value) {
  if (value == null) {
    return 0;
  }
  if (value is int) {
    return value < 0 ? 0 : value;
  }

  final digits = value.toString().replaceAll(RegExp(r'[^0-9]'), '');
  if (digits.isEmpty) {
    return 0;
  }
  return int.tryParse(digits) ?? 0;
}

bool _asBool(Object? value) {
  if (value is bool) {
    return value;
  }
  if (value is num) {
    return value == 1;
  }

  final text = value?.toString().trim().toLowerCase();
  return text == 'true' || text == '1';
}
