import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;

/// 桌面形态判定：仅由操作系统决定，与窗口大小无关。
///
/// 车机/平板/手机均为 Android，恒为 false，走既有布局路径；
/// Windows/macOS/Linux 视为桌面，启用桌面 Shell。
/// 全项目唯一的桌面平台判定入口，页面代码不得散落 Platform.isWindows。
final bool isDesktopFormFactor = !kIsWeb &&
    (Platform.isWindows || Platform.isMacOS || Platform.isLinux);
