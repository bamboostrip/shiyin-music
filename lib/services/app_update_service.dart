import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config/app_config.dart';
import '../models/app_version.dart';

/// 应用更新检查服务（数据源：GitHub Releases，无需后端）。
///
/// CI 打 `v*` tag 时会在 GitHub 发布带 APK 附件的 Release，本服务读取其公开
/// Releases API 判断是否有新版本；命中后由 UI 跳浏览器下载安装。
class AppUpdateService {
  AppUpdateService();

  /// 记录上一次"自动检查"成功请求的时间戳（毫秒），用于节流。
  static const _lastAutoCheckKey = 'update.last_auto_check_ms';

  /// 是否支持检查更新（仅非 Web 的 Android）。
  static bool get isSupportedPlatform {
    return !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  }

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

  /// 请求 GitHub 最新正式 Release 并映射为 [AppVersionInfo]。
  Future<AppVersionInfo> _fetchLatestFromGitHub() async {
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
    if (response.statusCode != 200) {
      throw StateError('请求 GitHub 失败（${response.statusCode}）');
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw StateError('GitHub 返回数据格式异常');
    }
    return AppVersionInfo.fromGitHubRelease(decoded);
  }

  /// 在外部浏览器打开更新包链接（直链 APK，或回退的 Release 页面）。
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
}
