class AppConfig {
  const AppConfig._();

  static const appName = '时音';
  static const appVersion = '2.4.6';
  static const appVersionCode = '246';

  static const debugLyrics = bool.fromEnvironment(
    'KA_MUSIC_DEBUG_LYRICS',
    defaultValue: true,
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
  static const githubReleasesLatestUrl =
      'https://api.github.com/repos/$githubRepoOwner/$githubRepoName/releases/latest';

  /// 请求 GitHub API 时的 User-Agent（GitHub 要求非空，否则 403）。
  static const githubUpdateUserAgent = 'ShiYin-App/$appVersion';

  /// 启动时自动检查更新的最小间隔（手动检查不受此限制）。
  static const updateAutoCheckInterval = Duration(hours: 24);
}
