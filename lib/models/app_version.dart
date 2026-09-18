import 'package:flutter/foundation.dart';

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

  /// 标准字段覆写复制（平台相关性选版后需要用拼接的 changelog 覆写
  /// [updateContent]，其余字段沿用 Release 原始数据）。
  AppVersionInfo copyWith({
    String? platform,
    String? versionName,
    int? versionCode,
    String? updateContent,
    String? downloadUrl,
    bool? forceUpdate,
    DateTime? releaseDate,
  }) {
    return AppVersionInfo(
      platform: platform ?? this.platform,
      versionName: versionName ?? this.versionName,
      versionCode: versionCode ?? this.versionCode,
      updateContent: updateContent ?? this.updateContent,
      downloadUrl: downloadUrl ?? this.downloadUrl,
      forceUpdate: forceUpdate ?? this.forceUpdate,
      releaseDate: releaseDate ?? this.releaseDate,
    );
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
  /// - 附件选择：Android 按 [renderer]+[abi] 选 `-skia`/`-impeller` 与
  ///   `-arm64`/`-arm32` 变体 `.apk`；
  ///   Windows 按 [windowsAssetKind] 选 `-portable.zip` / `-setup.exe`；
  ///   Linux 按 [linuxAsset] 选 `.deb` / `-portable.tar.gz`
  ///   （规则见 [pickUpdateAssetUrl]）。选不中回退 Release 页面 [htmlUrl]
  /// - GitHub 不提供"强制更新"，故 [forceUpdate] 恒为 false
  factory AppVersionInfo.fromGitHubRelease(
    Map<String, dynamic> json, {
    String htmlUrl = '',
    String renderer = '',
    String abi = '',
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
      abi: abi,
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
/// - Android：按「渲染引擎 + ABI」逐级放宽匹配 `.apk`——
///   1. 同时含 `-$renderer` 与 `-$abi`（如 `shiyin-v3.0.2-skia-arm32.apk`）；
///   2. 含 `-$abi`（附件命名无渲染段的兜底）；
///   3. 含 `-$renderer`（老 Release 无本 ABI 附件时只能拿另一架构——
///      v3.0.2 前只发过 arm64，不存在 32 位正式用户，可接受）；
///   4. 第一个 `.apk`（兼容双包之前的老 Release；发版时 impeller 包
///      放前面，老客户端行为不变）。
///
/// 选不中返回空字符串，调用方回退 Release 页面。
String pickUpdateAssetUrl(
  Iterable<(String, String)> assets, {
  String renderer = '',
  String abi = '',
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

  final apks = byExtension('.apk').toList();
  final want = renderer.trim().toLowerCase();
  final wantAbi = abi.trim().toLowerCase();

  String? firstContaining(String token) {
    for (final asset in apks) {
      if (asset.$1.toLowerCase().contains(token)) return asset.$2;
    }
    return null;
  }

  if (want.isNotEmpty && wantAbi.isNotEmpty) {
    for (final asset in apks) {
      final name = asset.$1.toLowerCase();
      if (name.contains('-$want') && name.contains('-$wantAbi')) {
        return asset.$2;
      }
    }
  }
  if (wantAbi.isNotEmpty) {
    final hit = firstContaining('-$wantAbi');
    if (hit != null) return hit;
  }
  if (want.isNotEmpty) {
    final hit = firstContaining('-$want');
    if (hit != null) return hit;
  }
  return apks.isEmpty ? '' : apks.first.$2;
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

/// 截掉 Release notes 里的「📥 下载」产物清单区（应用内更新弹窗用）。
///
/// 该区是给 Release 网页访客看的下载指引（各平台产物表格 + sha256
/// 校验说明，见 docs/release-process.md 笔记模板）；应用内弹窗只展示
/// 更新内容本身，避免一大段与本机无关的产物列表刷屏。
///
/// 规则：标题行精确为 `## 📥 下载` / `### 下载`（模板格式契约，标题就是
/// 「下载」两字，见 docs/release-process.md）时截到下一个二级标题或正文
/// 结束（模板约定下载区为最后一节）；整行精确匹配避免把「## 下载管理
/// 重构」这类真正的更新内容标题误当下载区吞掉。标题缺失的老 Release
/// 原样返回。标题匹配不带 `\b`：CJK 字符不属于 ECMAScript 的 `\w`，
/// `下载\b` 在中文后永远不成立。
String stripReleaseDownloadSection(String body) {
  final headingPattern = RegExp(r'^#{2,3}\s*(?:📥\s*)?下载\s*$');
  final h2Pattern = RegExp(r'^##\s+');
  final buffer = StringBuffer();
  var inDownloadSection = false;
  for (final rawLine in body.split('\n')) {
    final line = rawLine.trimLeft();
    if (!inDownloadSection) {
      if (headingPattern.hasMatch(line)) {
        inDownloadSection = true;
        continue;
      }
      buffer.writeln(rawLine);
    } else if (h2Pattern.hasMatch(line)) {
      // 下载区之后又出现二级标题：恢复输出（模板外的排版兜底）。
      inDownloadSection = false;
      buffer.writeln(rawLine);
    }
  }
  return buffer.toString().trimRight();
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

/// 由语义化版本生成一个单调的整数 code
/// （major*[_kMajorStride] + minor*[_kMinorStride] + patch）。
/// 口径必须与 docs/release-process.md 及 pubspec `+<code>` 后缀一致
/// （如 2.5.1 → 2005001）：fromGitHubRelease 用它与 AppConfig.appVersionCode
///（经 normalizedVersionCode 归一）比较新旧，口径分叉会导致同版本恒判"有更新"。
///
/// 历史口径是 `major*100 + minor*10 + patch`，minor/patch 达到 10 即高位进位
/// 破坏单调性（2.10.0 与 3.0.0 同为 300）。改为 3 位小数位后约束放宽到
/// minor/patch < 1000；新 code 恒大于任何旧口径 code（旧值最多 3 位数，
/// 新值最少 7 位数），跨版本升级比较不会倒退。
int semverToCode(String version) {
  final p = _semverParts(version);
  return p[0] * _kMajorStride + p[1] * _kMinorStride + p[2];
}

/// 版本码十进制位宽（minor/patch 各占 [_kMinorStride] 的 3 位）。
const int _kMajorStride = 1000000;
const int _kMinorStride = 1000;

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

/// 解析 Release 说明中的「适用平台」标记行。
///
/// 标记格式（发版规范见 docs/release-process.md）：notes 首部一行
/// `> 适用平台：Windows、Linux`（blockquote，网页上人可读）。L1 拿到的
/// 是原始 markdown（带 `>` 前缀），L2 Atom 正文经 htmlReleaseBodyToMarkdown
/// 转换后是裸文本行，两者都要能解析。
///
/// 返回小写平台词集合：
/// - null = 未写标记（历史/全平台 Release，视为影响所有平台，安全兜底）；
/// - 含 'all' = 显式全平台；
/// - 其余为具体平台词（'windows'/'linux'/'android'，未来多端新增词需同步
///   此处词表与发版文档）。
/// 标记存在但解析不出任何已知词 → {'all'}（宁多提示不漏提示）。
@visibleForTesting
Set<String>? parseApplicablePlatforms(String text) {
  final match = RegExp(
    r'^\s*>?\s*\**\s*适用平台\s*[：:]\s*(.+)$',
    multiLine: true,
  ).firstMatch(text);
  if (match == null) {
    return null;
  }
  final platforms = <String>{};
  for (final raw in match.group(1)!.split(RegExp(r'[、，,/\s]+'))) {
    // 小写匹配：中文词无大小写，英文词（Windows/All 等）统一归一。
    switch (raw.trim().toLowerCase()) {
      case '全平台' || 'all':
        platforms.add('all');
      case 'windows' || 'win':
        platforms.add('windows');
      case 'linux':
        platforms.add('linux');
      case 'pc' || '桌面' || '桌面端':
        // PC/桌面端没有单一平台词，等价展开为两桌面平台。
        platforms
          ..add('windows')
          ..add('linux');
      case 'android' || '安卓' || '移动端' || '手机':
        platforms.add('android');
    }
  }
  // 标记存在但全是未知词：按全平台处理，宁可多提示不漏提示。
  return platforms.isEmpty ? const {'all'} : platforms;
}

/// Release 是否影响当前平台。[platforms] 为 [parseApplicablePlatforms] 的
/// 结果；[myPlatform] 为 'android'/'windows'/'linux'。
@visibleForTesting
bool releaseAffectsPlatform(Set<String>? platforms, String myPlatform) {
  // null = 未写标记的历史/全平台 Release，安全兜底视为影响所有平台。
  if (platforms == null) {
    return true;
  }
  if (platforms.contains('all')) {
    return true;
  }
  return platforms.contains(myPlatform);
}
