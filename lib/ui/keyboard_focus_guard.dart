import 'package:flutter/material.dart';

/// 焦点是否位于输入框或按钮等可交互控件内（基于 [FocusManager]）。
///
/// 桌面全局快捷键共用此守卫（AppShortcutScope 的空格/方向键与
/// DesktopShell 的 Ctrl+F / Ctrl+1-6 / Enter）：焦点在控件内时全局
/// 快捷键应退让，让按键落到控件默认行为（编辑文本/激活按钮）上，
/// 避免遮蔽按钮自身的 Enter/空格激活。
/// 检查类型含 InkWell：修复焦点落在 InkWell 卡片上时空格/Enter 无响应。
bool isFocusInsideInteractiveControl() {
  final context = FocusManager.instance.primaryFocus?.context;
  if (context == null) return false;
  return isContextInsideInteractiveControl(context);
}

/// 纯函数版交互控件判定：从 [context] 沿祖先链向上找首个命中。
bool isContextInsideInteractiveControl(BuildContext context) {
  var interactive = false;
  context.visitAncestorElements((element) {
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

/// 焦点是否位于可滚动区域内部（且不在输入框/按钮等交互控件内）。
///
/// 桌面端空格快捷键的退让判定：焦点落在普通可滚动内容（列表/页面）
/// 上时空格应交给滚动（翻页），而不是触发全局播放/暂停；
/// 焦点在交互控件内时优先返回 false（控件自身消费空格）。
bool isFocusInsideScrollableRegion() {
  final context = FocusManager.instance.primaryFocus?.context;
  if (context == null) return false;
  return isContextInsideScrollableRegion(context);
}

/// 纯函数版可滚动区域判定（见 [isFocusInsideScrollableRegion]）。
bool isContextInsideScrollableRegion(BuildContext context) {
  if (isContextInsideInteractiveControl(context)) return false;
  return Scrollable.maybeOf(context) != null;
}

/// 焦点所在可滚动区域翻一页（桌面空格退让的执行端）。
///
/// Flutter 的 [Scrollable] 本身不处理键盘事件，"交给滚动"需要主动执行：
/// 向 [forward] 方向滚动约一个视口高度（clamp 到滚动范围内）。
/// 返回是否实际执行了翻页。
bool scrollFocusedRegionByPage({required bool forward}) {
  final context = FocusManager.instance.primaryFocus?.context;
  if (context == null) return false;
  if (isContextInsideInteractiveControl(context)) return false;
  final scrollable = Scrollable.maybeOf(context);
  if (scrollable == null) return false;
  final position = scrollable.position;
  if (!position.hasContentDimensions || !position.hasViewportDimension) {
    return false;
  }
  final delta = position.viewportDimension * (forward ? 1 : -1);
  final target = (position.pixels + delta).clamp(
    position.minScrollExtent,
    position.maxScrollExtent,
  );
  if (target == position.pixels) return false;
  position.moveTo(
    target,
    duration: const Duration(milliseconds: 200),
    curve: Curves.easeOutCubic,
  );
  return true;
}

/// 输入法是否处于组词（composing）状态（IME 守卫）。
///
/// 纯防御：组词期间的 Enter 是"选词"而非"确认"，搜索框
/// onSubmitted 若照常提交会误发搜索。三端生效，触屏端无行为风险。
bool isImeComposingActive(TextEditingValue value) =>
    value.composing != TextRange.empty;

/// 带守卫的回调动作：[guard] 命中时跳过 [onInvoke]。
///
/// 桌面端（[desktop]=true）守卫命中时返回 [KeyEventResult.ignored]
/// 放行按键 —— 让事件继续冒泡到框架默认 Shortcuts（空格/Enter →
/// ActivateIntent），从而激活焦点所在的 InkWell/按钮等控件；
/// 移动端保持历史行为：跳过 onInvoke 但仍消费按键
/// （等价于旧 CallbackAction 的"no-op + 消费"）。
class GuardedCallbackAction<T extends Intent> extends Action<T> {
  GuardedCallbackAction({
    required this.desktop,
    required this.guard,
    required this.onInvoke,
  });

  /// 是否按桌面语义放行被守卫拦截的按键。
  final bool desktop;

  /// 守卫：返回 true 时跳过 [onInvoke]（焦点在交互控件内等场景）。
  final bool Function(T intent) guard;

  /// 实际动作（命名对齐 [CallbackAction.onInvoke]）。
  final Object? Function(T intent) onInvoke;

  static const Object _yielded = 'yielded';

  @override
  Object? invoke(covariant T intent) {
    if (guard(intent)) return _yielded;
    return onInvoke(intent);
  }

  @override
  KeyEventResult toKeyEventResult(covariant T intent, covariant Object? invokeResult) {
    if (desktop && identical(invokeResult, _yielded)) {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }
}
