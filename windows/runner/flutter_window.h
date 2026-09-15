#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <memory>
#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // shiyin_music/window 通道：Dart → runner 的主窗原生配置
  // （目前仅 setEraseBackground，见 OnCreate）。
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      window_channel_;

  // OnDestroy 起置位：controller 析构（无障碍桥拆除）会同步派发嵌套窗口
  // 消息重入 MessageHandler，此时 view 正在析构，进 Flutter 消息分发会
  // 访问已释放对象（GetEngine）导致退出崩溃（崩溃后 WER 收集转储拖
  // ~12s 才退出，表现为"退出卡住"）。
  bool is_shutting_down_ = false;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
