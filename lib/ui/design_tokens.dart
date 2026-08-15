import 'package:flutter/material.dart';

/// 全局设计规范 Token：圆角 / 间距 / 阴影。
/// 新代码请优先使用这里定义的常量，避免散落魔法数值。
abstract final class AppRadius {
  static const double xs = 6;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 24;
}

abstract final class AppSpacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
}

abstract final class AppShadow {
  /// 常规卡片阴影。
  static const List<BoxShadow> card = [
    BoxShadow(color: Color(0x14000000), blurRadius: 10, offset: Offset(0, 2)),
  ];
}
