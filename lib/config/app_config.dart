class AppConfig {
  const AppConfig._();

  static const appName = '时音';
  static const appVersion = '3.0.18';

  /// 版本码口径：major*1000000 + minor*1000 + patch（见 models/app_version.dart
  /// 的 semverToCode 与 docs/release-process.md）。3.0.16 → 3000016。
  static const appVersionCode = '3000018';

  /// 酷狗系接口/CDN 的 Android 客户端 UA（与 rust/src/kugou/config.rs 一致）。
  /// 播放走本机代理注入（music_audio_handler），歌曲下载由 dio 请求头携带；
  /// CDN 若校验 UA，缺失会导致"流播放正常但下载/播放缓存 403"。
  static const kugouUserAgent =
      'Android15-1070-11083-46-0-DiscoveryDRADProtocol-wifi';

  /// 当前包的渲染引擎，由构建时 `--dart-define=APP_RENDERER=skia|impeller`
  /// 烘焙进来（CI 矩阵 / build_apk.bat 负责传）。更新检查用它选对应附件；
  /// 本地 `flutter run` 没传时按 Impeller 默认处理。
  static const renderer = String.fromEnvironment(
    'APP_RENDERER',
    defaultValue: 'impeller',
  );

  /// 当前包的目标 ABI，由构建时 `--dart-define=APP_ABI=arm64|arm32`
  /// 烘焙进来（CI 矩阵 / build_apk.bat 负责传；产物名含 `-$abi-`，
  /// 如 `shiyin-v3.0.2-skia-arm32.apk`）。更新检查配合 [renderer] 选包，
  /// 32 位车机拿到 arm64 包无法安装。本地构建默认 arm64。
  static const abi = String.fromEnvironment(
    'APP_ABI',
    defaultValue: 'arm64',
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
  /// 数据缓存目录名 / 下载目录名 / 播放缓存目录名。
  /// 旧名（ka_music_*）由 services/legacy_migration.dart 在启动时自动迁移，
  /// 改动这里的值必须同步维护迁移映射，否则老用户下载/缓存"消失"。
  ///
  /// [cacheDirName] 目前是封面磁盘缓存的根目录（临时目录之下，
  /// 见 services/image_disk_cache.dart）；数据缓存本身存在 SharedPreferences。
  static const cacheDirName = 'shiyin_cache';
  static const downloadDirName = 'shiyin_downloads';
  static const playCacheDirName = 'shiyin_play_cache';

  /// 下载/播放缓存目录的改名前旧名（legacy_migration 与 DownloadService 的
  /// 历史目录对账共用，单点维护）。
  static const legacyDownloadDirName = 'ka_music_downloads';
  static const legacyPlayCacheDirName = 'ka_music_play_cache';

  /// 数据缓存 TTL（分级）
  static const homeCacheTtl = Duration(minutes: 30); // 首页推荐
  static const rankCacheTtl = Duration(minutes: 30); // 排行榜（与推荐页对齐）
  static const radioCacheTtl = Duration(minutes: 30); // 电台（与推荐页对齐）
  static const playlistDetailTtl = Duration(hours: 24); // 歌单/专辑详情
  static const userProfileTtl = Duration(hours: 24); // 用户信息+歌单列表

  /// 播放缓存大小上限（超过则按 LRU 清理），下载不设上限（用户主动管理）
  static const playCacheMaxBytes = 300 * 1024 * 1024; // 300MB

  // ===== 歌词磁盘缓存（每首歌一个文件，不进 SharedPreferences）=====
  /// 歌词缓存目录名（挂在应用支持目录下，见 services/lyric_cache_service.dart）。
  ///
  /// 历史实现把每首歌的歌词存进 SharedPreferences（`cache_lyric_<hash>`），
  /// Windows 上每次写都要整文件 JSON 编解码（十几 MB 时单次数百毫秒），
  /// 是冷启动/切歌卡顿的主因；现改为按 hash 独立文件 + 容量上限。
  static const lyricCacheDirName = 'lyric_cache';

  /// 歌词缓存总容量上限（超出按最后访问时间淘汰到 80%）。
  static const lyricCacheMaxBytes = 32 * 1024 * 1024; // 32MB ≈ 1200 首

  /// 歌词缓存 TTL：超过该时长且未再访问的条目在启动裁剪时清理。
  static const lyricCacheTtl = Duration(days: 30);

  // ===== SharedPreferences 数据缓存治理 =====
  /// 仍存在 SharedPreferences 里的数据缓存（首页/歌单/专辑/歌手/用户/本地
  /// 歌词匹配）单前缀最多保留的条数：超出按 `savedAt` 从旧到新淘汰。
  ///
  /// 这些 key 是"可重建的缓存"，不设上限会在长期使用后把 prefs 撑到几 MB，
  /// 进而放大 Windows 每次写盘的整文件编解码开销（见 services/
  /// prefs_compaction.dart）。
  static const Map<String, int> dataCachePrefixCaps = <String, int>{
    'cache_playlist_collection_': 30,
    'cache_playlist_': 30,
    'cache_album_': 30,
    'cache_artist_': 30,
    'cache_local_lyric_v1_': 200,
  };

  /// 单条缓存的最大字符数：超过直接不缓存（如超长歌单的"全量歌曲表"），
  /// 避免一个 key 就把 prefs 撑到需要整文件重编码的体量。
  static const int dataCacheMaxEntryChars = 2 * 1024 * 1024; // ~2MB

  /// 每次缓存写入最多淘汰的条数：历史积压不能一次性触发几十次整文件重写
  /// （那正是本issue要消灭的卡顿来源），让积压随多次写入逐步收敛。
  static const int dataCacheEvictionsPerWrite = 3;

  /// 所有 `cache_*` 值合计字符数预算（≈字节，JSON 以 ASCII 为主）。
  ///
  /// 条数上限管不住"条数没超但单条很大"（如超长歌单全量歌曲表、本地歌词
  /// 匹配缓存），prefs 仍可能被撑回十几 MB；瘦身逻辑在启动时按此预算从最旧
  /// 开始淘汰。
  static const int dataCacheMaxChars = 4 * 1024 * 1024;

  /// 缓存内容未变时，`savedAt` 至少间隔多久才重写一次。
  ///
  /// 去重能省掉大量整文件重写，但若永远不刷新 savedAt，"内容未变但已过期"
  /// 的条目会被一直判为过期（如歌单详情每次都全量重拉所有分页）。定期把
  /// savedAt 推进一次即可：一次写盘 / 10 分钟 / 活跃 key，成本可忽略。
  static const Duration cacheSavedAtRefreshAfter = Duration(minutes: 10);

  // ===== 图片（封面）缓存配置 =====
  /// 内存 ImageCache 上限。
  ///
  /// 移动端/车机口径不变（200 张 / 64MB）：车机 2-4GB RAM，内存必须克制，
  /// 且车机一屏铺开的封面数远低于该上限，命中率本来就够。
  static const imageMemoryCacheMaxCount = 200;
  static const imageMemoryCacheMaxBytes = 64 * 1024 * 1024; // 64MB

  /// 桌面端内存上限：宽窗一屏能铺开几百张封面（推荐页桌面端把当天全部
  /// 歌曲/歌单转成网格），沿用移动端口径会长期处于 LRU 淘汰状态——条目
  /// 被淘汰后再次解析只能重新走网络，表现为"进出播放页后整页封面变白
  /// 再逐张回来"。放宽到移动端 1.5 倍条目 / 2 倍字节（此前 600 张 /
  /// 256MB 常驻内存偏高，收敛为保守档）；被淘汰的条目由桌面 200MB 磁盘
  /// 缓存（[desktopImageDiskCacheMaxBytes]）兜底，Android 不读这两个值。
  static const desktopImageMemoryCacheMaxCount = 300;
  static const desktopImageMemoryCacheMaxBytes = 128 * 1024 * 1024; // 128MB

  /// 封面磁盘缓存上限（0 = 关闭）。只占存储不占 RAM：
  /// 内存条目被淘汰或 App 冷启动时，命中磁盘即可直接解码，不必等网络往返。
  /// 封面平均 20~60KB，50MB 可容纳上千张，对车机存储也无压力。
  static const imageDiskCacheMaxBytes = 50 * 1024 * 1024; // 50MB
  static const desktopImageDiskCacheMaxBytes = 200 * 1024 * 1024; // 200MB

  /// 封面磁盘缓存目录名（挂在 [cacheDirName] 之下）。
  static const imageCacheDirName = 'image';

  /// 下载并发数
  static const maxConcurrentDownloads = 3;

  // ===== 检查更新（GitHub Releases，无后端） =====
  /// 托管 Release / APK 的 GitHub 仓库。CI 打 tag 时会在此发布带 APK 附件的 Release。
  static const githubRepoOwner = 'bamboostrip';
  static const githubRepoName = 'shiyin-music';

  /// GitHub Releases 最新正式版接口（公开仓库无需鉴权，但必须带 User-Agent）。
  /// 注意：api.github.com 未鉴权限额 60 次/时/IP，超限返回 403。
  /// 更新检查已改走 [githubReleasesListUrl] 做平台相关性选版；此 URL 保留供
  /// docs/release-process.md FAQ 的手工验证命令使用。
  static const githubReleasesLatestUrl =
      'https://api.github.com/repos/$githubRepoOwner/$githubRepoName/releases/latest';

  /// GitHub Releases 列表接口（按创建时间倒序，含预发布；每个元素带 body 与
  /// assets）。更新检查用它取"最近若干版本"做平台相关性判断，见
  /// docs/release-process.md 的「版本适用平台标记」。
  static const githubReleasesListUrl =
      'https://api.github.com/repos/$githubRepoOwner/$githubRepoName/releases?per_page=30';

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
