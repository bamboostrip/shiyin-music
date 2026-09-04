#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <desktop_multi_window/desktop_multi_window_plugin.h>
#include <window_manager/window_manager_plugin.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
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
