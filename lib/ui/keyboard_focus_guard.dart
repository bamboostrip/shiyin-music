import 'package:flutter/material.dart';

/// 焦点是否位于输入框或按钮等可交互控件内。
///
/// 桌面全局快捷键共用此守卫（[AppShortcutScope] 的空格/方向键与
/// DesktopShell 的 Ctrl+F / Ctrl+1-3 / Enter）：焦点在控件内时全局
/// 快捷键应退让，让按键落到控件默认行为（编辑文本/激活按钮）上，
/// 避免遮蔽按钮自身的 Enter/空格激活。
/// 检查类型含 InkWell：修复焦点落在 InkWell 卡片上时空格/Enter 无响应。
bool isFocusInsideInteractiveControl() {
  final focused = FocusManager.instance.primaryFocus;
  if (focused == null || focused.context == null) return false;
  var interactive = false;
  focused.context!.visitAncestorElements((element) {
    final widget = element.widget;
    if (widget is EditableText ||
        widget is SelectableText ||
        widget is ButtonStyleButton ||
        widget is IconButton ||
        widget is RawMaterialButton ||
        widget is InkWell) {
      interactive = true;
      return false;
    }
    return true;
  });
  return interactive;
}
