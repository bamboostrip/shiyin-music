#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <desktop_multi_window/desktop_multi_window_plugin.h>

#include "flutter_window.h"
#include "flutter/generated_plugin_registrant.h"
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
  // flutter_window.cc：仅 InternalMultiWindowPlugin + WindowChannel）。
  // 通过窗口创建回调为子引擎补齐主工程全部插件（window_manager、
  // shared_preferences 等），桌面歌词悬浮窗才能在子引擎中调用这些通道。
  DesktopMultiWindowSetWindowCreatedCallback(
      [](void *view_controller) {
        RegisterPlugins(reinterpret_cast<flutter::FlutterViewController *>(
                            view_controller)
                            ->engine());
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
