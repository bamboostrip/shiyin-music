import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;

/// 原生平台宿主是否为桌面 OS（Web 下本文件不会被编译，见 os_detect_web）。
bool get hostIsDesktop =>
    !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);
