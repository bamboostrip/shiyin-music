#ifndef RUNNER_OVERLAY_FOCUS_GUARD_H_
#define RUNNER_OVERLAY_FOCUS_GUARD_H_

#include <windows.h>

// 桌面歌词悬浮窗的焦点隔离。
//
// 背景（Windows 11 + Flutter 3.44.8 实测，2026-11）：
// 「打开桌面歌词 → 关闭主窗到托盘 → 关闭悬浮窗 → 从托盘恢复主窗」之后，
// 整个进程的中文输入法失效：拼音直接以拉丁字母上屏、候选框不再弹出，
// 换任何输入法（微软拼音 / 微信 / 豆包）都一样，只有重启应用才恢复；
// 反过来，重新打开一次桌面歌词又能让输入法恢复。
//
// 原因不在 Dart 层：悬浮窗与主窗共享同一 UI 线程与 TSF 线程管理器。
// 悬浮窗一显示（engine 窗口创建 / ShowWindow）就会把键盘焦点和 TSF 焦点
// 文档从主窗 FLUTTERVIEW 抢走；主窗在托盘里时再关掉悬浮窗，线程的输入法
// 开/关 compartment（GUID_COMPARTMENT_KEYBOARD_OPENCLOSE）就永久丢失——
// IMM32 层看起来正常（ImmGetContext 非空、ImmGetOpenStatus=TRUE），但系统
// 不再投递任何 WM_IME_* 组词消息，主窗恢复后也补不回来。该行为与
// flutter/flutter#190042 一致；Flutter Windows 引擎不管理输入上下文
// （3.44.8 全量只有 7 个 Imm* 调用，没有 ImmAssociateContext*，也不碰 TSF），
// 所以只能由 runner 在窗口层保证：悬浮窗永远不持有键盘焦点。
//
// 具体做法见 main.cpp：
// - 悬浮窗顶层禁止激活（WS_EX_NOACTIVATE + 强制 SWP_NOACTIVATE +
//   WM_MOUSEACTIVATE 返回 MA_NOACTIVATE），配套 vendored 的
//   desktop_multi_window 把 Show() 改成 SW_SHOWNOACTIVATE；
// - 悬浮窗 FLUTTERVIEW 一旦收到 WM_SETFOCUS，立刻把焦点还给主窗视图
//   （[MainFlutterView]）——这是兜底也是最终生效的一层。
namespace shiyin {

// 主窗 Flutter 子窗口（FLUTTERVIEW）HWND，由 FlutterWindow::OnCreate 登记。
inline HWND& MainFlutterView() {
  static HWND hwnd = nullptr;
  return hwnd;
}

}  // namespace shiyin

#endif  // RUNNER_OVERLAY_FOCUS_GUARD_H_
