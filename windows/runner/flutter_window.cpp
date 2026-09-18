#include "flutter_window.h"

#include <optional>

#include <flutter/encodable_value.h>
#include <flutter/method_result.h>
#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"

namespace {

// FLUTTERVIEW（引擎子窗口）实例子类化：其窗口类同样无刷底，最大化/缩放
// 过渡期子窗新暴露的边缘在 Flutter 下一帧呈现前也会闪黑。与顶层窗口
// （Win32Window::MessageHandler 的 WM_ERASEBKGND）共用同一份擦除快照，
// 只填"新暴露"的差异带并保留旧画面，避免整屏闪色；首个到达的擦除填充
// 差异并推进快照，后续擦除自然为空操作。
WNDPROC g_flutter_view_original_proc = nullptr;

LRESULT CALLBACK FlutterViewEraseBkgndProc(HWND hwnd,
                                           UINT const message,
                                           WPARAM const wparam,
                                           LPARAM const lparam) noexcept {
  if (message == WM_ERASEBKGND && g_flutter_view_original_proc != nullptr) {
    Win32Window::FillExposedEdgesOnErase(
        hwnd, reinterpret_cast<HDC>(wparam));
    return 1;
  }
  return CallWindowProc(g_flutter_view_original_proc, hwnd, message, wparam,
                        lparam);
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // shiyin_music/window 通道：Dart 按当前主题同步最大化/缩放过渡期的
  // 原生擦除底色（setEraseBackground，参数 0x00RRGGBB），消除窗口边缘
  // 闪黑；顶层与 FLUTTERVIEW 子窗口共用该底色。
  window_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "shiyin_music/window",
          &flutter::StandardMethodCodec::GetInstance());
  window_channel_->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
             result) {
        if (call.method_name() == "setEraseBackground") {
          const auto* arguments = call.arguments();
          int64_t color = 0;
          if (arguments != nullptr) {
            if (const auto* v32 = std::get_if<int32_t>(arguments)) {
              color = *v32;
            } else if (const auto* v64 = std::get_if<int64_t>(arguments)) {
              color = *v64;
            }
          }
          // Dart 传 0x00RRGGBB；COLORREF 内存布局为 0x00BBGGRR。
          Win32Window::SetEraseBackgroundColor(RGB(
              static_cast<int>((color >> 16) & 0xFF),
              static_cast<int>((color >> 8) & 0xFF),
              static_cast<int>(color & 0xFF)));
          result->Success();
        } else {
          result->NotImplemented();
        }
      });

  // FLUTTERVIEW 子窗口擦底子类化（仅主窗视图一次）。
  HWND flutter_view = flutter_controller_->view()->GetNativeWindow();
  if (flutter_view != nullptr && g_flutter_view_original_proc == nullptr) {
    g_flutter_view_original_proc = reinterpret_cast<WNDPROC>(SetWindowLongPtr(
        flutter_view, GWLP_WNDPROC,
        reinterpret_cast<LONG_PTR>(FlutterViewEraseBkgndProc)));
  }

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  // 必须先置标记再析构 controller：析构过程中无障碍桥（AX bridge）拆除
  // 会同步派发嵌套窗口消息（WM_GETOBJECT 类）重入 MessageHandler，此时
  // view 正在析构，若继续进 Flutter 消息分发，GetEngine 会访问已释放
  // 对象导致退出时崩溃（之后 WER 收集转储拖 ~12s 进程才退出）。
  //
  // 仅当 controller 存在时才处理：启动期 Win32Window::Create() 开头会
  // 防御性调用一次 Destroy()→OnDestroy()（此时窗口与 controller 均未
  // 创建），若那里也置位 is_shutting_down_，标志将永久为 true，之后每次
  // WM_CLOSE 都会跳过 Flutter 消息分发（preventClose 拦截随之失效），
  // 窗口被立即销毁并走进上文的崩溃路径。
  if (flutter_controller_ != nullptr) {
    is_shutting_down_ = true;
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // 单实例激活直达主窗：先于 Flutter 引擎分发处理，避免引擎消费该消息
  // 后基类收不到（与 Win32Window::MessageHandler 的处理幂等）。
  const UINT activate_message = Win32Window::SingleInstanceActivateMessageId();
  if (activate_message != 0 && message == activate_message) {
    Win32Window::BringWindowToFront(hwnd);
    return 0;
  }
  // Give Flutter, including plugins, an opportunity to handle window messages.
  // 销毁期间（is_shutting_down_）跳过：重入消息交给 DefWindowProc 即可。
  if (flutter_controller_ && !is_shutting_down_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }

    switch (message) {
      case WM_FONTCHANGE:
        flutter_controller_->engine()->ReloadSystemFonts();
        break;
    }
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
