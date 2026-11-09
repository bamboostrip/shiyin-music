import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/app_config.dart';
import 'prefs_compaction.dart';

/// 旧标识（KA Music / kgka 时代）→ 时音命名的一次性迁移。
///
/// 覆盖四类用户数据，保证改名对老用户零感知：
/// 1. 平台应用数据目录（必须最先执行，见下）：
///    - Windows：`%APPDATA%\com.example\时音` → `%APPDATA%\shiyin\时音`
///      （VERSIONINFO CompanyName 改名；Roaming/Local 各一份，内含
///      SharedPreferences 的 shared_preferences.json 与 Rust 引擎的
///      kg_session.json）；
///    - Linux：`~/.local/share/com.hoilai.mm.music`（旧 GTK app id）、
///      `~/.local/share/kgka_music_hl`（旧二进制名兜底）→
///      `~/.local/share/top.famlife.shiyin`（尊重 XDG_DATA_HOME）；
///    - macOS：`~/Library/Application Support/<bundle-id>` 与
///      `~/Library/Preferences/<bundle-id>.plist`（NSUserDefaults 键域）
///      按 bundle id 改名搬迁（CI 暂不分发 macOS，尽力而为）。
/// 2. SharedPreferences 键：`ka_music_*` → `shiyin_*`（登录态、收藏、
///    歌单缓存、下载/播放缓存索引）；
/// 3. 磁盘目录：`ka_music_downloads` / `ka_music_play_cache` →
///    `shiyin_*`（父目录不变，整目录 rename；随后重写索引里的绝对路径）。
///
/// 顺序约束（关键）：平台目录搬移必须先于 `SharedPreferences.getInstance()`
/// 与一切 path_provider 调用——它们会立即**创建**新路径的空目录并从新路径
/// 读数据，一旦先跑，旧键永远读不到、目录搬移还会把空新目录误判为
/// "已迁移"而跳过（Windows/Linux 均受影响）。
///
/// 设计约束：
/// - 任一步失败都不得阻断启动：各阶段独立 try/catch，失败只留日志；
/// - 幂等：旧键复制成功后即删除，旧目录移动后不存在，重复执行为 no-op；
/// - 目录移动失败（权限/新旧目录都非空）时**不重写索引**——旧绝对路径
///   仍然有效，最坏情况是"新旧目录并存"，绝不丢下载记录。
///
/// Android 通知渠道 ID 的迁移在原生侧 MusicApplication.kt 完成
/// （系统渠道 API 无法从 Dart 删除）；MethodChannel 名纯内部通信无数据
/// 迁移需求，双端同步改名即可。
class LegacyMigration {
  const LegacyMigration._();

  /// 旧下载目录名（AppConfig.downloadDirName 改名前的值）。
  static const _oldDownloadsDirName = AppConfig.legacyDownloadDirName;
  /// 旧播放缓存目录名（AppConfig.playCacheDirName 改名前的值）。
  static const _oldPlayCacheDirName = AppConfig.legacyPlayCacheDirName;

  /// 精确键映射（旧 → 新）。
  static const _exactKeys = <String, String>{
    'ka_music_token': 'shiyin_token',
    'ka_music_t1': 'shiyin_t1',
    'ka_music_session_id': 'shiyin_session_id',
    'ka_music_user_id': 'shiyin_user_id',
    'ka_music_liked_hashes': 'shiyin_liked_hashes',
    'ka_music_cached_playlists': 'shiyin_cached_playlists',
    'ka_music_playlist_empty_count': 'shiyin_playlist_empty_count',
    'ka_music_downloads_index': 'shiyin_downloads_index',
    'ka_music_play_cache_index': 'shiyin_play_cache_index',
  };

  /// 动态后缀键的前缀映射（如 `ka_music_cached_playlists_<userId>`）。
  /// 精确键与动态前缀共用同一命名时，先按精确表复制，再扫前缀兜底
  /// 残余的动态键，两遍互不冲突（精确表已删旧键）。
  static const _prefixPairs = <(String, String)>[
    ('ka_music_cached_playlists', 'shiyin_cached_playlists'),
    ('ka_music_playlist_empty_count', 'shiyin_playlist_empty_count'),
  ];

  /// 旧标识常量：Linux 旧 GTK app id（linux/CMakeLists.txt 改名前）。
  static const _oldLinuxAppId = 'com.hoilai.mm.music';
  /// 旧标识常量：Linux 旧二进制名（path_provider 的可执行名兜底目录）。
  static const _oldLinuxBinaryName = 'kgka_music_hl';
  /// 新 GTK app id（linux/CMakeLists.txt APPLICATION_ID）。
  static const _newLinuxAppId = 'top.famlife.shiyin';
  /// 旧标识常量：macOS 旧 bundle id（AppInfo.xcconfig 改名前）。
  static const _oldMacosBundleId = 'com.example.kgkaMusicHl';
  /// 新 bundle id（AppInfo.xcconfig PRODUCT_BUNDLE_IDENTIFIER）。
  static const _newMacosBundleId = 'top.famlife.shiyin';

  /// 在 runApp 之前（且必须先于 RustApiClient.getInstance——它拿到的是
  /// 平台支持目录，见 _migratePlatformDataDirs）调用一次。
  ///
  /// [includePlatformDataDirs] 仅供单元测试关闭真实用户目录搬移
  /// （flutter test 运行在开发者真机上，Platform.environment 指向真实
  /// %APPDATA% / $HOME），生产路径一律保持默认 true。
  static Future<void> run({
    bool includePlatformDataDirs = true,
  }) async {
    // 平台目录搬移必须最先：getInstance()/path_provider 会创建新路径的
    // 空目录并从新路径读数据，先跑会导致键迁移读不到旧键、目录搬移被
    // 空新目录误判跳过。
    if (includePlatformDataDirs) {
      try {
        await _migratePlatformDataDirs();
      } catch (error, stack) {
        debugPrint('[时音][migration] 平台数据目录迁移异常（已跳过）: $error\n$stack');
      }
      // prefs 瘦身必须夹在「目录搬移之后、第一次 getInstance() 之前」：
      // 目录搬移完成才能对当前目录的文件生效；一旦插件读过一次，整张 map
      // 就进了内存，再改文件会被下一次写盘覆盖回去（详见 PrefsCompaction）。
      await PrefsCompaction.runIfNeeded();
    }
    SharedPreferences? prefs;
    try {
      prefs = await SharedPreferences.getInstance();
      await _migratePrefKeys(prefs);
    } catch (error, stack) {
      debugPrint('[时音][migration] 旧键迁移异常（已跳过）: $error\n$stack');
    }
    if (prefs == null) return;
    // 下载/播放缓存目录迁移彼此独立，任一失败不影响另一个。
    try {
      await _migrateDownloadsDir(prefs);
    } catch (error, stack) {
      debugPrint('[时音][migration] 下载目录迁移异常（已跳过）: $error\n$stack');
    }
    try {
      await _migratePlayCacheDir(prefs);
    } catch (error, stack) {
      debugPrint('[时音][migration] 播放缓存目录迁移异常（已跳过）: $error\n$stack');
    }
  }

  // ===== SharedPreferences 键 =====

  static Future<void> _migratePrefKeys(SharedPreferences prefs) async {
    final keys = prefs.getKeys();
    // 1. 精确映射
    for (final entry in _exactKeys.entries) {
      if (keys.contains(entry.key)) {
        await _copyPref(prefs, entry.key, entry.value);
      }
    }
    // 2. 动态前缀键（getKeys 是快照，逐对前缀扫描）
    for (final (oldPrefix, newPrefix) in _prefixPairs) {
      for (final key in keys) {
        if (key.startsWith(oldPrefix) && !_exactKeys.containsKey(key)) {
          await _copyPref(prefs, key, newPrefix + key.substring(oldPrefix.length));
        }
      }
    }
  }

  static Future<void> _copyPref(
    SharedPreferences prefs,
    String from,
    String to,
  ) async {
    final value = prefs.get(from);
    if (value == null) return;
    if (prefs.containsKey(to)) {
      // 新键已有值（迁移中断后重跑等）：以新键为准，清旧键即可。
      await prefs.remove(from);
      return;
    }
    final ok = switch (value) {
      final String s => await prefs.setString(to, s),
      final bool b => await prefs.setBool(to, b),
      final int i => await prefs.setInt(to, i),
      final double d => await prefs.setDouble(to, d),
      final List<String> l => await prefs.setStringList(to, l),
      _ => false,
    };
    if (ok) {
      await prefs.remove(from);
    } else {
      debugPrint('[时音][migration] 迁移键 $from → $to 写入失败，保留旧键');
    }
  }

  // ===== 磁盘目录 + 索引内绝对路径 =====

  static Future<void> _migrateDownloadsDir(SharedPreferences prefs) async {
    final parent = await _downloadsParentDir();
    if (parent == null) return;
    await _migrateDir(
      prefs,
      oldPath: '${parent.path}${Platform.pathSeparator}$_oldDownloadsDirName',
      newPath: '${parent.path}${Platform.pathSeparator}${AppConfig.downloadDirName}',
      indexKey: 'shiyin_downloads_index',
      oldName: _oldDownloadsDirName,
      newName: AppConfig.downloadDirName,
    );
  }

  static Future<void> _migratePlayCacheDir(SharedPreferences prefs) async {
    Directory? base;
    try {
      base = await getTemporaryDirectory();
    } catch (_) {}
    if (base == null) return;
    await _migrateDir(
      prefs,
      oldPath: '${base.path}${Platform.pathSeparator}$_oldPlayCacheDirName',
      newPath: '${base.path}${Platform.pathSeparator}${AppConfig.playCacheDirName}',
      indexKey: 'shiyin_play_cache_index',
      oldName: _oldPlayCacheDirName,
      newName: AppConfig.playCacheDirName,
    );
  }

  /// 镜像 DownloadService.downloadDir() 的父目录解析（Android 专属外部
  /// 目录 → 桌面 Downloads → 文档目录兜底），只到父级，不拼接子目录。
  static Future<Directory?> _downloadsParentDir() async {
    try {
      if (Platform.isAndroid) {
        final external = await getExternalStorageDirectory();
        if (external != null) return external;
        return await getApplicationDocumentsDirectory();
      }
      if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
        final downloads = await getDownloadsDirectory();
        if (downloads != null) return downloads;
      }
      return await getApplicationDocumentsDirectory();
    } catch (_) {
      return null;
    }
  }

  /// 整目录 rename 迁移旧目录，成功后重写索引 JSON 字符串里的目录名段。
  static Future<void> _migrateDir(
    SharedPreferences prefs, {
    required String oldPath,
    required String newPath,
    required String indexKey,
    required String oldName,
    required String newName,
  }) async {
    final oldDir = Directory(oldPath);
    final newDir = Directory(newPath);
    if (!await oldDir.exists()) {
      // 旧目录不存在：全新安装，或目录已迁移但索引重写曾在中断中失败——
      // 仍尝试重写一次（幂等 replaceAll，对已重写值无副作用）。
      await _rewriteIndex(prefs, indexKey, oldName, newName);
      return;
    }
    if (await newDir.exists() && await _directoryHasEntries(newDir)) {
      // 新旧目录都非空：不做合并（避免同名覆盖），旧索引路径继续有效，
      // 新下载自然落到新目录。
      debugPrint('[时音][migration] $oldName 与 $newName 并存，跳过目录合并');
      return;
    }
    try {
      // rename 到已存在的空目录在 POSIX 会 ENOTEMPTY/EEXIST，Windows 同理
      // 要求目标不存在；新目录若是本次 path_provider 刚建的空壳，先删。
      if (await newDir.exists()) await newDir.delete();
      await oldDir.rename(newPath);
      await _rewriteIndex(prefs, indexKey, oldName, newName);
      debugPrint('[时音][migration] 已迁移目录 $oldName → $newName');
    } catch (error) {
      // 跨卷 rename 等失败：保持旧路径可用，不重写索引。
      debugPrint('[时音][migration] 目录 $oldName 迁移失败（保留旧路径）: $error');
    }
  }

  static Future<bool> _directoryHasEntries(Directory dir) async {
    try {
      return dir.listSync(recursive: false, followLinks: false).isNotEmpty;
    } catch (_) {
      // 列不出来按"非空"保守处理，不动用户数据。
      return true;
    }
  }

  static Future<void> _rewriteIndex(
    SharedPreferences prefs,
    String indexKey,
    String oldName,
    String newName,
  ) async {
    final raw = prefs.getString(indexKey);
    if (raw == null || !raw.contains(oldName)) return;
    await prefs.setString(
      indexKey,
      raw.replaceAll(oldName, newName),
    );
  }

  // ===== 平台应用数据目录（CompanyName / app id / bundle id 改名连带） =====

  static Future<void> _migratePlatformDataDirs() async {
    if (Platform.isWindows) {
      await _migrateWindowsCompanyDirs();
    } else if (Platform.isLinux) {
      await _migrateLinuxDataDirs();
    } else if (Platform.isMacOS) {
      await _migrateMacosDataDirs();
    }
  }

  /// VERSIONINFO CompanyName 从 com.example 改为 shiyin 后，
  /// path_provider_windows 的 support/cache 目录变为
  /// `%APPDATA%\shiyin\时音` / `%LOCALAPPDATA%\shiyin\时音`。
  /// 整目录搬移（内含 Rust 引擎 kg_session.json 与
  /// shared_preferences.json），登录态不丢。
  static Future<void> _migrateWindowsCompanyDirs() async {
    final env = Platform.environment;
    for (final (envKey, label) in [('APPDATA', 'Roaming'), ('LOCALAPPDATA', 'Local')]) {
      final root = env[envKey];
      if (root == null || root.isEmpty) continue;
      final moves = windowsCompanyDirMoves(root, AppConfig.appName);
      await _moveDataDir(
        oldPath: moves.$1,
        newPath: moves.$2,
        label: '$label 应用数据目录（com.example → shiyin）',
      );
    }
  }

  /// 纯路径计算（便于单测）：单个根目录下 `%root%\com.example\<app>` →
  /// `%root%\shiyin\<app>`。
  @visibleForTesting
  static (String, String) windowsCompanyDirMoves(String root, String appName) {
    return (
      '$root\\com.example\\$appName',
      '$root\\shiyin\\$appName',
    );
  }

  /// Linux：path_provider_linux 的 support 目录 = `$XDG_DATA_HOME/<GTK
  /// app id>`（缺失时回退 `~/.local/share/<可执行名>`）。app id 与二进制
  /// 名同时改名，旧数据按两种旧名兜底搬移到新 app id 目录。
  static Future<void> _migrateLinuxDataDirs() async {
    final env = Platform.environment;
    final dataHome = env['XDG_DATA_HOME'];
    final home = env['HOME'];
    if ((dataHome == null || dataHome.isEmpty) && (home == null || home.isEmpty)) {
      return;
    }
    final base = linuxDataHome(dataHome, home);
    for (final (oldPath, newPath) in linuxDataDirMoves(dataHome, home)) {
      await _moveDataDir(
        oldPath: oldPath,
        newPath: newPath,
        label: 'Linux 数据目录（$base 内，改名前标识 → $_newLinuxAppId）',
      );
    }
  }

  /// XDG 数据根目录（与 xdg_directories 的解析保持一致）。
  @visibleForTesting
  static String linuxDataHome(String? xdgDataHome, String? home) {
    final dataHome = xdgDataHome;
    if (dataHome != null && dataHome.isNotEmpty) return dataHome;
    return '$home/.local/share';
  }

  /// 纯路径计算（便于单测）：旧 app id / 旧二进制名两个候选目录 → 新
  /// app id 目录。两个候选都存在的极端情况下，第一个搬移成功后第二个
  /// 因目标非空自动跳过，不会互相覆盖。
  @visibleForTesting
  static List<(String, String)> linuxDataDirMoves(String? xdgDataHome, String? home) {
    if ((xdgDataHome == null || xdgDataHome.isEmpty) && (home == null || home.isEmpty)) {
      return const [];
    }
    final base = linuxDataHome(xdgDataHome, home);
    return [
      ('$base/$_oldLinuxAppId', '$base/$_newLinuxAppId'),
      ('$base/$_oldLinuxBinaryName', '$base/$_newLinuxAppId'),
    ];
  }

  /// macOS（尽力而为，CI 暂不分发）：非沙盒下 NSUserDefaults 键域存为
  /// `~/Library/Preferences/<bundle-id>.plist`，path_provider_foundation
  /// 的 support 目录为 `~/Library/Application Support/<bundle-id>`；沙盒
  /// 构建则整体位于 `~/Library/Containers/<bundle-id>`。三条路径全部
  /// 按新 bundle id 搬迁/复制。
  static Future<void> _migrateMacosDataDirs() async {
    final home = Platform.environment['HOME'];
    if (home == null || home.isEmpty) return;
    // 1) 沙盒容器：整目录 rename 即可带上全部数据。
    final moves = macosDataDirMoves(home);
    await _moveDataDir(
      oldPath: moves['containers']!,
      newPath: moves['containersNew']!,
      label: 'macOS 沙盒容器目录（$_oldMacosBundleId → $_newMacosBundleId）',
    );
    // 2) 非沙盒 support 目录（Rust kg_session.json）。
    await _moveDataDir(
      oldPath: moves['support']!,
      newPath: moves['supportNew']!,
      label: 'macOS Application Support 目录（$_oldMacosBundleId → $_newMacosBundleId）',
    );
    // 3) 非沙盒 NSUserDefaults：plist 复制（保留旧文件，防 cfprefsd
    //    回写旧域时无档可写），目标已存在则以目标为准。
    final oldPlist = File(moves['prefs']!);
    final newPlist = File(moves['prefsNew']!);
    try {
      if (await oldPlist.exists() && !await newPlist.exists()) {
        await oldPlist.copy(newPlist.path);
        debugPrint('[时音][migration] 已复制 macOS 偏好域 $_oldMacosBundleId → $_newMacosBundleId');
      }
    } catch (error) {
      debugPrint('[时音][migration] macOS 偏好域复制失败: $error');
    }
  }

  /// 纯路径计算（便于单测）。
  @visibleForTesting
  static Map<String, String> macosDataDirMoves(String home) {
    final prefRoot = '$home/Library/Preferences';
    final supportRoot = '$home/Library/Application Support';
    return {
      'containers': '$home/Library/Containers/$_oldMacosBundleId',
      'containersNew': '$home/Library/Containers/$_newMacosBundleId',
      'support': '$supportRoot/$_oldMacosBundleId',
      'supportNew': '$supportRoot/$_newMacosBundleId',
      'prefs': '$prefRoot/$_oldMacosBundleId.plist',
      'prefsNew': '$prefRoot/$_newMacosBundleId.plist',
    };
  }

  /// 通用目录搬移：旧目录不存在 → no-op；新目录非空 → 跳过（绝不合并
  /// 覆盖）；新目录为空壳（path_provider/上次中断误建）→ 删除后 rename。
  static Future<void> _moveDataDir({
    required String oldPath,
    required String newPath,
    required String label,
  }) async {
    final oldDir = Directory(oldPath);
    final newDir = Directory(newPath);
    if (!await oldDir.exists()) return;
    try {
      if (await newDir.exists()) {
        if (await _directoryHasEntries(newDir)) {
          debugPrint('[时音][migration] $label：目标已存在且非空，跳过合并');
          return;
        }
        // rename 要求目标不存在：空壳目录先删。
        await newDir.delete();
      }
      // rename 要求父目录存在。
      final parent = newDir.parent;
      if (!await parent.exists()) await parent.create(recursive: true);
      await oldDir.rename(newPath);
      debugPrint('[时音][migration] 已迁移 $label');
    } catch (error) {
      debugPrint('[时音][migration] $label 迁移失败（保留旧路径）: $error');
    }
  }
}
