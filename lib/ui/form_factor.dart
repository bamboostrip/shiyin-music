import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;

/// 测试注入开关：非 null 时 [isDesktopFormFactor] 直接返回该值。
///
/// 仅用于 widget 测试在任意宿主上覆盖桌面/非桌面双形态；
/// 业务代码禁止写入。
bool? debugDesktopFormFactorOverride;

final bool _osIsDesktop =
    !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

/// 桌面形态判定：仅由操作系统决定，与窗口大小无关。
///
/// 车机/平板/手机均为 Android，恒为 false，走既有布局路径；
/// Windows/macOS/Linux 视为桌面，启用桌面 Shell。
/// 全项目唯一的桌面平台判定入口，页面代码不得散落 Platform.isWindows。
bool get isDesktopFormFactor =>
    debugDesktopFormFactorOverride ?? _osIsDesktop;
