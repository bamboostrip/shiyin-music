import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Android 共享存储（公共目录）访问状态。
///
/// 「所有文件访问」（`MANAGE_EXTERNAL_STORAGE`）自 Android 11（API 30）起
/// 提供：授权后 dart:io 才能按路径读写公共目录（如
/// `/storage/emulated/0/Music`）。file_picker 选目录只返回路径、不携带 SAF
/// 授权（插件没有 takePersistableUriPermission），因此公共目录的按路径
/// 写入只能依赖该权限。
///
/// 版本差异：
/// - Android 11+（API 30+）：可在系统设置里授予「所有文件访问」；
/// - Android 10（API 29）：强制分区存储且没有该权限开关，公共目录按路径
///   写入无法授权，只能写应用专属目录（[canRequest] 为 false）；
/// - Android 9 及以下（API <= 28）：沿用 `WRITE_EXTERNAL_STORAGE` 运行时权限。
@immutable
class AndroidStorageAccessStatus {
  const AndroidStorageAccessStatus({
    required this.sdkInt,
    required this.granted,
    required this.canRequest,
  });

  /// 非 Android 平台的中性值：视为已授权，不干扰各平台既有目录逻辑。
  static const AndroidStorageAccessStatus notAndroid =
      AndroidStorageAccessStatus(sdkInt: 0, granted: true, canRequest: false);

  /// 原生通道不可用（通道未注册/读取失败）时的保守值：按不可用处理，
  /// 调用方回退默认下载目录。
  static const AndroidStorageAccessStatus unavailable =
      AndroidStorageAccessStatus(sdkInt: 0, granted: false, canRequest: false);

  /// 系统 API 级别；非 Android 平台为 0。
  final int sdkInt;

  /// 当前是否已能按路径写公共目录。
  final bool granted;

  /// 是否还能通过系统设置页申请（Android 10 为 false）。
  final bool canRequest;

  /// 平台是否具备「自定义公共目录」能力（已授权或仍可申请）。
  bool get supported => granted || canRequest;

  @override
  String toString() =>
      'AndroidStorageAccessStatus(sdkInt: $sdkInt, granted: $granted, '
      'canRequest: $canRequest)';
}

/// Android「所有文件访问」/ 传统存储权限的查询与申请。
///
/// 与 `android/app/src/main/kotlin/shiyin/famlife/top/MainActivity.kt` 里
/// 通道 `shiyin_music/storage` 一一对应；非 Android 平台与测试环境走本地
/// 兜底，不触碰原生通道。
class AndroidStorageAccess {
  const AndroidStorageAccess._();

  /// 原生通道名（MainActivity 注册）。
  static const MethodChannel channel = MethodChannel('shiyin_music/storage');

  /// 测试注入开关：非 null 时替代 [Platform.isAndroid]，便于在桌面宿主上
  /// 用 mock 通道覆盖 Android 分支（与 `debugDesktopFormFactorOverride`
  /// 同思路）。
  @visibleForTesting
  static bool? debugForceAndroid;

  static bool get _isAndroid => debugForceAndroid ?? Platform.isAndroid;

  /// 查询当前存储访问状态。
  static Future<AndroidStorageAccessStatus> status() async {
    if (!_isAndroid) return AndroidStorageAccessStatus.notAndroid;
    try {
      final raw = await channel.invokeMapMethod<String, Object?>('getStatus');
      if (raw == null) return AndroidStorageAccessStatus.unavailable;
      return AndroidStorageAccessStatus(
        sdkInt: (raw['sdkInt'] as num?)?.toInt() ?? 0,
        granted: raw['granted'] == true,
        canRequest: raw['canRequest'] == true,
      );
    } on MissingPluginException {
      // 通道未注册（旧版原生代码/非 Android 宿主）：按不可用处理，下载
      // 回退应用专属目录，不影响默认功能。
      debugPrint('[AndroidStorageAccess] 原生存储通道未注册，按不可用处理');
    } on PlatformException catch (error) {
      debugPrint('[AndroidStorageAccess] 读取存储权限状态失败: $error');
    }
    return AndroidStorageAccessStatus.unavailable;
  }

  /// 是否已能按路径写公共目录。
  static Future<bool> hasSharedStorageAccess() async =>
      (await status()).granted;

  /// 申请存储访问权限；Android 11+ 会跳到「所有文件访问」设置页，用户
  /// 返回后给出系统真实授权结果。Android 10 直接返回 false。
  static Future<bool> requestAccess() async {
    if (!_isAndroid) return true;
    try {
      final granted = await channel.invokeMethod<bool>('requestAccess');
      return granted ?? false;
    } on MissingPluginException {
      debugPrint('[AndroidStorageAccess] 原生存储通道未注册，无法申请权限');
    } on PlatformException catch (error) {
      debugPrint('[AndroidStorageAccess] 申请存储权限失败: $error');
    }
    return false;
  }

  /// 通知系统媒体库扫描刚写入公共目录的文件。
  ///
  /// 按路径写入（而非 MediaStore 插入）的文件不会自动进媒体库：不扫描的话
  /// 车机、其他播放器、相册要等下次系统全盘扫描才看得到。应用专属目录的
  /// 文件会被系统忽略，调用无副作用；任何失败都只记日志，不影响下载结果。
  static Future<void> scanFile(String path) async {
    if (!_isAndroid || path.trim().isEmpty) return;
    try {
      await channel.invokeMethod<bool>('scanFile', {'path': path});
    } on MissingPluginException {
      // 旧版原生没有该能力：文件仍在磁盘，只是媒体库暂时看不到
    } on PlatformException catch (error) {
      debugPrint('[AndroidStorageAccess] 媒体库扫描失败: $error');
    }
  }
}

/// [path] 是否位于 [directories] 之一（含子目录）。
///
/// 应用专属目录（`Android/data/<包名>/files`、应用文档目录）无需「所有文件
/// 访问」即可写入；用路径前缀判断即可，不需要真实访问磁盘。分隔符统一按
/// `/` 比较并忽略末尾分隔符，Windows 风格反斜杠也能匹配。
bool isPathWithinDirectories(String path, Iterable<String> directories) {
  final normalizedPath = _normalizeDirectoryPath(path);
  if (normalizedPath.isEmpty) return false;
  for (final directory in directories) {
    final normalizedDir = _normalizeDirectoryPath(directory);
    if (normalizedDir.isEmpty) continue;
    if (normalizedPath == normalizedDir ||
        normalizedPath.startsWith('$normalizedDir/')) {
      return true;
    }
  }
  return false;
}

String _normalizeDirectoryPath(String path) {
  var normalized = path.trim().replaceAll('\\', '/');
  while (normalized.length > 1 && normalized.endsWith('/')) {
    normalized = normalized.substring(0, normalized.length - 1);
  }
  return normalized;
}
