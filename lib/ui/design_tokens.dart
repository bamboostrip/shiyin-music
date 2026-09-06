import 'package:flutter/material.dart';

/// 全局设计规范 Token：圆角 / 间距 / 阴影。
/// 新代码请优先使用这里定义的常量，避免散落魔法数值。
abstract final class AppRadius {
  static const double xs = 6;
  static const double sm = 8;
  /// 底部弹窗顶部圆角（紧凑、优雅，QQ 音乐风格）
  static const double sheet = 10;
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

/// 桌面形态专属主题 Token：滚动条 / Tooltip / 页面转场。
///
/// 仅桌面形态（isDesktopFormFactor）由 AppTheme 条件注入；
/// 移动端/车机不使用，保持 Flutter 默认，主题逐项不变。
abstract final class AppDesktopTheme {
  /// 滚动条常态厚度（细条）。
  static const double scrollbarThickness = 6;

  /// 滚动条 hover 厚度（加粗）。
  static const double scrollbarHoverThickness = 9;

  /// 滚动条圆角（取常态厚度一半，视觉为全圆细条）。
  static const Radius scrollbarRadius = Radius.circular(3);

  /// 滚动条 thumb 距视口边缘的横向间距。
  static const double scrollbarCrossAxisMargin = 2;

  /// 滚动条 thumb 距滚动区两端的纵向留白。
  static const double scrollbarMainAxisMargin = 4;

  /// 滚动条 thumb 最小长度（Flutter 默认 18）：短列表不至于
  /// thumb 过短难以命中，也避免边界处长度剧烈变化产生闪烁。
  static const double scrollbarMinThumbLength = 48;

  /// 桌面 Tooltip 统一等待时长（全项目唯一取值来源）。
  static const Duration tooltipWaitDuration = Duration(milliseconds: 500);

  /// 桌面页面转场时长（轻快 fade，替代移动端 Material Zoom 的 300ms）。
  static const Duration pageTransitionDuration = Duration(milliseconds: 180);
}
