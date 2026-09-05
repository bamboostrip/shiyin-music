class AppConfig {
  const AppConfig._();

  static const appName = '时音';
  static const appVersion = '2.5.1';
  static const appVersionCode = '251';

  /// 当前包的渲染引擎，由构建时 `--dart-define=APP_RENDERER=skia|impeller`
  /// 烘焙进来（CI 矩阵 / build_apk.bat 负责传）。更新检查用它选对应附件；
  /// 本地 `flutter run` 没传时按 Impeller 默认处理。
  static const renderer = String.fromEnvironment(
    'APP_RENDERER',
    defaultValue: 'impeller',
  );

  /// 渲染引擎展示名（关于页 / 日志用）。
  static String get rendererLabel => renderer == 'skia' ? 'Skia' : 'Impeller';

  static const debugLyrics = bool.fromEnvironment(
    'SHIYIN_DEBUG_LYRICS',
    defaultValue: bool.fromEnvironment(
      'KA_MUSIC_DEBUG_LYRICS',
      defaultValue: true,
    ),
  );

  // ===== 缓存与下载配置 =====
  /// 数据缓存目录名 / 下载目录名 / 播放缓存目录名
  static const cacheDirName = 'ka_music_cache';
  static const downloadDirName = 'ka_music_downloads';
  static const playCacheDirName = 'ka_music_play_cache';

  /// 数据缓存 TTL（分级）
  static const homeCacheTtl = Duration(minutes: 30); // 首页推荐
  static const playlistDetailTtl = Duration(hours: 24); // 歌单/专辑详情
  static const userProfileTtl = Duration(hours: 24); // 用户信息+歌单列表

  /// 播放缓存大小上限（超过则按 LRU 清理），下载不设上限（用户主动管理）
  static const playCacheMaxBytes = 300 * 1024 * 1024; // 300MB

  /// 下载并发数
  static const maxConcurrentDownloads = 3;

  // ===== 检查更新（GitHub Releases，无后端） =====
  /// 托管 Release / APK 的 GitHub 仓库。CI 打 tag 时会在此发布带 APK 附件的 Release。
  static const githubRepoOwner = 'bamboostrip';
  static const githubRepoName = 'shiyin-music';

  /// GitHub Releases 最新正式版接口（公开仓库无需鉴权，但必须带 User-Agent）。
  /// 注意：api.github.com 未鉴权限额 60 次/时/IP，超限返回 403。
  static const githubReleasesLatestUrl =
      'https://api.github.com/repos/$githubRepoOwner/$githubRepoName/releases/latest';

  /// 仓库网页根。以下三个 github.com 域端点不占 API 频次，
  /// 作为 API 403/超时时的多级容灾渠道（对齐 handwrite-sim 的 updater 策略）。
  static const githubRepoUrl =
      'https://github.com/$githubRepoOwner/$githubRepoName';

  /// Releases Atom 订阅源：取最新 tag 与更新说明正文（第一降级渠道）。
  static const githubReleasesAtomUrl = '$githubRepoUrl/releases.atom';

  /// /releases/latest 网页 302 重定向探测最新 tag（最后兜底）。
  static const githubReleasesLatestPageUrl = '$githubRepoUrl/releases/latest';

  /// 请求 GitHub API 时的 User-Agent（GitHub 要求非空，否则 403）。
  static const githubUpdateUserAgent = 'ShiYin-App/$appVersion';

  /// 启动时自动检查更新的最小间隔（手动检查不受此限制）。
  static const updateAutoCheckInterval = Duration(hours: 24);
}
