#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <desktop_multi_window/desktop_multi_window_plugin.h>
#include <window_manager/window_manager_plugin.h>

#include <map>

#include "flutter_window.h"
#include "overlay_focus_guard.h"
#include "utils.h"
#include "win32_window.h"

namespace {

// 桌面歌词悬浮窗顶层 / 视图（FLUTTERVIEW）HWND → 原子类窗口过程。
// 只在 UI 线程读写，无需加锁。
std::map<HWND, WNDPROC> g_overlay_original_procs;
std::map<HWND, WNDPROC> g_overlay_view_original_procs;

// 悬浮窗视图（FLUTTERVIEW）子类过程。
//
// 悬浮窗视图一旦拿到键盘焦点，TSF 焦点文档就从主窗换到悬浮窗；主窗在
// 托盘里时再关掉悬浮窗，线程的输入法开/关 compartment 就永久丢失，主窗
// 恢复后中文输入法不能组词（详见 overlay_focus_guard.h 与 flutter#190042）。
// 悬浮窗没有任何键盘输入需求：抢到焦点立刻还给主窗视图，保证 TSF 焦点
// 文档始终挂在本线程主窗上。
LRESULT CALLBACK OverlayViewProc(HWND hwnd,
                                 UINT const message,
                                 WPARAM const wparam,
                                 LPARAM const lparam) noexcept {
  if (message == WM_SETFOCUS) {
    HWND main_view = shiyin::MainFlutterView();
    if (main_view != nullptr && main_view != hwnd && ::IsWindow(main_view)) {
      ::SetFocus(main_view);
      return 0;
    }
  } else if (message == WM_NCDESTROY) {
    auto it = g_overlay_view_original_procs.find(hwnd);
    WNDPROC original = nullptr;
    if (it != g_overlay_view_original_procs.end()) {
      original = it->second;
      g_overlay_view_original_procs.erase(it);
    }
    return original != nullptr
               ? ::CallWindowProc(original, hwnd, message, wparam, lparam)
               : ::DefWindowProc(hwnd, message, wparam, lparam);
  }
  auto it = g_overlay_view_original_procs.find(hwnd);
  if (it != g_overlay_view_original_procs.end()) {
    return ::CallWindowProc(it->second, hwnd, message, wparam, lparam);
  }
  return ::DefWindowProc(hwnd, message, wparam, lparam);
}

// 悬浮窗顶层窗口的子类过程：让悬浮窗永远不激活。
// - WM_WINDOWPOSCHANGING：给所有 SetWindowPos 强制 SWP_NOACTIVATE
//   （window_manager 的 setAlwaysOnTop 走 SetWindowPos(HWND_TOPMOST) 且
//   没带 SWP_NOACTIVATE，会直接激活悬浮窗——实测确认的抢焦点来源之一）。
// - WM_MOUSEACTIVATE：点击歌词也不激活，主窗保持前台。
// 最后一层兜底是 OverlayViewProc 的焦点归还。
LRESULT CALLBACK OverlayWindowProc(HWND hwnd,
                                   UINT const message,
                                   WPARAM const wparam,
                                   LPARAM const lparam) noexcept {
  if (message == WM_WINDOWPOSCHANGING) {
    auto* pos = reinterpret_cast<WINDOWPOS*>(lparam);
    if (pos != nullptr) {
      pos->flags |= SWP_NOACTIVATE;
    }
  } else if (message == WM_MOUSEACTIVATE) {
    return MA_NOACTIVATE;
  } else if (message == WM_NCDESTROY) {
    WNDPROC original = nullptr;
    auto it = g_overlay_original_procs.find(hwnd);
    if (it != g_overlay_original_procs.end()) {
      original = it->second;
      g_overlay_original_procs.erase(it);
    }
    return original != nullptr
               ? ::CallWindowProc(original, hwnd, message, wparam, lparam)
               : ::DefWindowProc(hwnd, message, wparam, lparam);
  }
  auto it = g_overlay_original_procs.find(hwnd);
  if (it != g_overlay_original_procs.end()) {
    return ::CallWindowProc(it->second, hwnd, message, wparam, lparam);
  }
  return ::DefWindowProc(hwnd, message, wparam, lparam);
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // 单实例判定必须在一切初始化之前：第二实例零副作用唤醒已有窗口后立即
  // 退出，不写任何状态、不初始化 COM/Flutter。互斥体句柄保活到进程结束
  // （故意不 CloseHandle）：进程退出/被任务管理器强杀时内核自动销毁，
  // 无"幽灵锁"（与 Dart 侧硬终止退出天然契合）。
  // 安装版与便携版共用同一互斥体名（产品级全局单实例）。
  // 注意：desktop_multi_window 的歌词子窗是同进程第二个 Flutter 引擎，
  // 不走 wWinMain，天然不受此判定影响。
  HANDLE single_instance_mutex =
      ::CreateMutexW(nullptr, TRUE, Win32Window::SingleInstanceMutexName());
  const DWORD single_instance_error = ::GetLastError();
  const bool already_running = (single_instance_mutex != nullptr &&
                                single_instance_error == ERROR_ALREADY_EXISTS);
  if (already_running) {
    // B（主）：私有广播由已有实例自己抢前台（绕前台锁定，见
    // Win32Window::MessageHandler）；A（兜底）：第二实例直接 FindWindow
    // 置前，覆盖已有实例尚未处理广播的窗口期。
    // 歌词悬浮窗的原生类名为 FlutterMultiWindow，与主窗类名不冲突，
    // 按类名查找不会找错。
    const UINT activate_message =
        Win32Window::SingleInstanceActivateMessageId();
    if (activate_message != 0) {
      ::PostMessageW(HWND_BROADCAST, activate_message, 0, 0);
    }
    // 并发竞态：连续快速双击时第一实例可能尚未 CreateWindow，重试后放弃。
    HWND existing_window = nullptr;
    for (int i = 0; i < 3; ++i) {
      existing_window = ::FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", nullptr);
      if (existing_window != nullptr) {
        break;
      }
      ::Sleep(200);
    }
    Win32Window::BringWindowToFront(existing_window);
    ::CloseHandle(single_instance_mutex);
    return EXIT_SUCCESS;
  }
  // 第一实例：single_instance_mutex 留在栈上直到消息循环结束（进程级
  // 生命周期），全程持有互斥体；故意不 CloseHandle，进程死亡时内核回收。
  // CreateMutex 失败（返回 nullptr）时无法 enforce 单实例，仍继续启动。
  (void)single_instance_mutex;

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  // desktop_multi_window 创建的子窗口引擎默认只注册该插件自身（见插件源码
  // flutter_window.cc：InternalMultiWindowPlugin + WindowChannel(id)，
  // 后者已把子引擎 "mixin.one/flutter_multi_window_channel" 的原生处理器
  // 绑定为子窗自身）。回调里禁止 RegisterPlugins 全量注册：重复注册
  // DesktopMultiWindowPlugin 会再建一个 WindowChannel(0) 覆盖子引擎处理器，
  // 且 AttachFlutterMainWindow 因主窗已存在早退，临时 WindowChannel 析构时
  // 调用 SetMethodCallHandler(nullptr)，子窗 -> 主窗的 windowClosed 随之
  // 丢失。这里仿照包示例（desktop_multi_window example/flutter_window.cc 的
  // DesktopLifecyclePlugin）只补注册悬浮窗必需的 window_manager；
  // shared_preferences_windows 为纯 Dart 插件（dartPluginClass），无需原生注册。
  DesktopMultiWindowSetWindowCreatedCallback(
      [](void *view_controller) {
        auto *flutter_view_controller =
            reinterpret_cast<flutter::FlutterViewController *>(view_controller);
        auto *registry = flutter_view_controller->engine();
        WindowManagerPluginRegisterWithRegistrar(
            registry->GetRegistrarForPlugin("WindowManagerPlugin"));

        // 桌面歌词悬浮窗禁止激活（WS_EX_NOACTIVATE）。
        //
        // 该窗与主窗共享同一 UI 线程与 TSF 线程管理器。DesktopMultiWindow 的
        // WindowController.show() 走 ShowWindow(SW_SHOW)，会把这个置顶窗
        // 激活，TSF 的焦点文档随之从主窗 FLUTTERVIEW 移到悬浮窗；此后若
        // 主窗在托盘里而悬浮窗被关闭/隐藏，线程的输入法开/关 compartment
        // （GUID_COMPARTMENT_KEYBOARD_OPENCLOSE）就再也回不来：主窗恢复后
        // 中文输入法不再组词（拼音直接以拉丁字母上屏、没有候选框，换任何
        // 输入法都一样），只能重启进程——与 flutter/flutter#190042 记录的
        // 行为一致。悬浮窗没有任何文本输入需求，禁止激活既从源头避免这个
        // 状态，也顺带避免点歌词时主窗变灰失焦。
        //
        // 注意：SetWindowLongPtr 必须在窗口显示前设置，这里正是
        // createWindow 后、子窗 Dart 首帧 show() 前的时机。
        if (flutter_view_controller->view() != nullptr) {
          HWND view_hwnd =
              flutter_view_controller->view()->GetNativeWindow();
          HWND root_hwnd =
              view_hwnd != nullptr ? ::GetAncestor(view_hwnd, GA_ROOT) : nullptr;
          if (root_hwnd != nullptr) {
            LONG_PTR ex_style = ::GetWindowLongPtr(root_hwnd, GWL_EXSTYLE);
            ::SetWindowLongPtr(root_hwnd, GWL_EXSTYLE,
                               ex_style | WS_EX_NOACTIVATE);
            // 仅靠 ex-style 挡不住 SetWindowPos(HWND_TOPMOST) 的显式激活，
            // 再子类化顶层窗口过程强制 SWP_NOACTIVATE / MA_NOACTIVATE。
            if (g_overlay_original_procs.find(root_hwnd) ==
                g_overlay_original_procs.end()) {
              WNDPROC original = reinterpret_cast<WNDPROC>(::SetWindowLongPtr(
                  root_hwnd, GWLP_WNDPROC,
                  reinterpret_cast<LONG_PTR>(OverlayWindowProc)));
              if (original != nullptr) {
                g_overlay_original_procs[root_hwnd] = original;
              }
            }
          }
          // 视图（FLUTTERVIEW）也子类化：抢到键盘焦点立刻还给主窗视图，
          // 保证 TSF 焦点文档永远挂在本线程主窗上（见 OverlayViewProc）。
          if (view_hwnd != nullptr &&
              g_overlay_view_original_procs.find(view_hwnd) ==
                  g_overlay_view_original_procs.end()) {
            WNDPROC original = reinterpret_cast<WNDPROC>(::SetWindowLongPtr(
                view_hwnd, GWLP_WNDPROC,
                reinterpret_cast<LONG_PTR>(OverlayViewProc)));
            if (original != nullptr) {
              g_overlay_view_original_procs[view_hwnd] = original;
            }
          }
        }
      });

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"\x65F6\x97F3", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
