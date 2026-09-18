#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <desktop_multi_window/desktop_multi_window_plugin.h>
#include <window_manager/window_manager_plugin.h>

#include "flutter_window.h"
#include "utils.h"
#include "win32_window.h"

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
