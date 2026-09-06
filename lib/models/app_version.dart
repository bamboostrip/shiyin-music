import '../config/app_config.dart';
import 'music_models.dart';

enum AppUpdatePlatform {
  android('android'),
  ios('ios'),
  hm('hm'),
  windows('windows'),
  linux('linux');

  const AppUpdatePlatform(this.apiValue);

  final String apiValue;
}

/// Windows 分发形态的附件标识（见 [pickUpdateAssetUrl]）。
const kWindowsAssetPortable = 'portable';
const kWindowsAssetSetup = 'setup';

/// Linux 附件标识：优先 `.deb`（apt 安装），回退便携 `portable.tar.gz`。
const kLinuxAssetDeb = 'deb';

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
  /// - 附件选择：Android 按 [renderer] 选 `-skia`/`-impeller` 变体 `.apk`；
  ///   Windows 按 [windowsAssetKind] 选 `-portable.zip` / `-setup.exe`；
  ///   Linux 按 [linuxAsset] 选 `.deb` / `-portable.tar.gz`
  ///   （规则见 [pickUpdateAssetUrl]）。选不中回退 Release 页面 [htmlUrl]
  /// - GitHub 不提供"强制更新"，故 [forceUpdate] 恒为 false
  factory AppVersionInfo.fromGitHubRelease(
    Map<String, dynamic> json, {
    String htmlUrl = '',
    String renderer = '',
    String windowsAssetKind = '',
    bool linuxAsset = false,
  }) {
    final rawTag = asString(json['tag_name']) ?? '';
    final versionName = stripVersionTagPrefix(rawTag);

    final assets = <(String, String)>[];
    final assetJson = json['assets'];
    if (assetJson is List) {
      for (final asset in assetJson) {
        if (asset is! Map) continue;
        final name = asString(asset['name']) ?? '';
        final url = asString(asset['browser_download_url']) ?? '';
        if (name.isNotEmpty && url.isNotEmpty) assets.add((name, url));
      }
    }
    final picked = pickUpdateAssetUrl(
      assets,
      renderer: renderer,
      windowsAssetKind: windowsAssetKind,
      linuxAsset: linuxAsset,
    );
    final releasePageUrl = asString(json['html_url']) ?? htmlUrl;

    return AppVersionInfo(
      platform: windowsAssetKind.isNotEmpty
          ? AppUpdatePlatform.windows.apiValue
          : linuxAsset
          ? AppUpdatePlatform.linux.apiValue
          : AppUpdatePlatform.android.apiValue,
      versionName: versionName.isEmpty ? rawTag : versionName,
      versionCode: semverToCode(versionName),
      updateContent: asString(json['body']) ?? '',
      downloadUrl: picked.isNotEmpty ? picked : releasePageUrl,
      forceUpdate: false,
      releaseDate: DateTime.tryParse(asString(json['published_at']) ?? ''),
    );
  }
}

/// 从 Release 附件 `(文件名, 直链)` 列表中选出当前平台/形态的下载直链。
///
/// - Windows 便携版：优先 `*-portable.zip`，回退任意 `.zip`；
/// - Windows 安装版：优先 `*-setup.exe`，回退任意 `.exe`；
/// - Linux：优先 `.deb`，回退 `*-portable.tar.gz`；
/// - Android：优先文件名含 `-$renderer` 的 `.apk`（如
///   `shiyin-v2.5.1-skia-arm64.apk`），回退第一个 `.apk`
///   （兼容双包之前的老 Release；发版时 impeller 包放前面，老客户端行为不变）。
///
/// 选不中返回空字符串，调用方回退 Release 页面。
String pickUpdateAssetUrl(
  Iterable<(String, String)> assets, {
  String renderer = '',
  String windowsAssetKind = '',
  bool linuxAsset = false,
}) {
  final entries = <(String, String)>[
    for (final asset in assets)
      if (asset.$2.trim().isNotEmpty) asset,
  ];

  Iterable<(String, String)> byExtension(String ext) sync* {
    for (final asset in entries) {
      if (asset.$1.toLowerCase().endsWith(ext)) yield asset;
    }
  }

  if (windowsAssetKind == kWindowsAssetPortable) {
    return _firstUrl(byExtension('-portable.zip')) ??
        _firstUrl(byExtension('.zip')) ??
        '';
  }
  if (windowsAssetKind == kWindowsAssetSetup) {
    return _firstUrl(byExtension('-setup.exe')) ??
        _firstUrl(byExtension('.exe')) ??
        '';
  }
  if (linuxAsset) {
    return _firstUrl(byExtension('.deb')) ??
        _firstUrl(byExtension('-portable.tar.gz')) ??
        _firstUrl(byExtension('.tar.gz')) ??
        '';
  }

  final want = renderer.trim().toLowerCase();
  for (final asset in byExtension('.apk')) {
    if (want.isNotEmpty && asset.$1.toLowerCase().contains('-$want')) {
      return asset.$2;
    }
  }
  return _firstUrl(byExtension('.apk')) ?? '';
}

String? _firstUrl(Iterable<(String, String)> assets) =>
    assets.isEmpty ? null : assets.first.$2;

/// 去掉版本 tag 的前导 `v`/`V` 与首尾空白，例如 `v2.4.0` → `2.4.0`。
String stripVersionTagPrefix(String tag) {
  var t = tag.trim();
  if (t.length > 1 && (t.startsWith('v') || t.startsWith('V'))) {
    t = t.substring(1);
  }
  return t;
}

/// 是否为"正式版" tag：可选 v 前缀 + 纯数字点分段（`v2.4.0`、`2.4`）。
///
/// 预发布（`v2.6.0-beta`、`2.6.0-rc.1`）与任何带后缀的 tag 都不算——
/// GitHub API 的 /releases/latest 只返回最新正式版，L2（Atom）/L3（302
/// 探测）降级路径必须同样过滤，否则 API 限流时降级路径会把 beta 当正式
/// 更新推给用户，与 L1 的语义不一致。
bool isStableVersionTag(String tag) {
  return RegExp(r'^[vV]?\d+(\.\d+)*$').hasMatch(tag.trim());
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
