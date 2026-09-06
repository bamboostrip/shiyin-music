import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;

/// 测试或调试注入开关：非 null 时 [isDesktopFormFactor] 直接返回该值。
///
/// 既用于 widget 测试覆盖双形态，也可在开发调试时临时设为 false 体验移动端布局。
bool? debugDesktopFormFactorOverride;

/// 编译期参数：支持通过 `--dart-define=FORCE_MOBILE=true` 在 Windows/桌面宿主上直接调试移动端界面。
const bool _forceMobile = bool.fromEnvironment('FORCE_MOBILE');

final bool _osIsDesktop =
    !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

/// 操作系统是否属于桌面平台（不受 FORCE_MOBILE 覆盖影响）
bool get isDesktopPlatform => _osIsDesktop;

/// 桌面形态判定：仅由操作系统决定，与窗口大小无关。
///
/// 车机/平板/手机均为 Android，恒为 false，走既有布局路径；
/// Windows/macOS/Linux 视为桌面，启用桌面 Shell。
/// 全项目唯一的桌面平台判定入口，页面代码不得散落 Platform.isWindows。
///
/// 优先级：[debugDesktopFormFactorOverride] > `--dart-define=FORCE_MOBILE=true` > 操作系统判定
bool get isDesktopFormFactor {
  if (debugDesktopFormFactorOverride != null) {
    return debugDesktopFormFactorOverride!;
  }
  if (_forceMobile) {
    return false;
  }
  return _osIsDesktop;
}
