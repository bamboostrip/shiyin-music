#ifndef RUNNER_WIN32_WINDOW_H_
#define RUNNER_WIN32_WINDOW_H_

#include <windows.h>

#include <functional>
#include <memory>
#include <string>

// A class abstraction for a high DPI-aware Win32 Window. Intended to be
// inherited from by classes that wish to specialize with custom
// rendering and input handling
class Win32Window {
 public:
  struct Point {
    unsigned int x;
    unsigned int y;
    Point(unsigned int x, unsigned int y) : x(x), y(y) {}
  };

  struct Size {
    unsigned int width;
    unsigned int height;
    Size(unsigned int width, unsigned int height)
        : width(width), height(height) {}
  };

  Win32Window();
  virtual ~Win32Window();

  // Creates a win32 window with |title| that is positioned and sized using
  // |origin| and |size|. New windows are created on the default monitor. Window
  // sizes are specified to the OS in physical pixels, hence to ensure a
  // consistent size this function will scale the inputted width and height as
  // as appropriate for the default monitor. The window is invisible until
  // |Show| is called. Returns true if the window was created successfully.
  bool Create(const std::wstring& title, const Point& origin, const Size& size);

  // Show the current window. Returns true if the window was successfully shown.
  bool Show();

  // Release OS resources associated with window.
  void Destroy();

  // Inserts |content| into the window tree.
  void SetChildContent(HWND content);

  // Returns the backing Window handle to enable clients to set icon and other
  // window properties. Returns nullptr if the window has been destroyed.
  HWND GetHandle();

  // If true, closing this window will quit the application.
  void SetQuitOnClose(bool quit_on_close);

  // 设置窗口原生擦除底色（最大化/缩放过渡期新暴露区域的填充色）。
  //
  // 窗口类 hbrBackground 为 0 且内容是异步绘制的 Flutter 画面，过渡期
  // 新暴露的边缘默认会闪黑；Dart 侧按当前主题经 shiyin_music/window 通道
  // 同步底色。顶层窗口与 FLUTTERVIEW 子窗口共用一份。
  static void SetEraseBackgroundColor(COLORREF color);

  // WM_WINDOWPOSCHANGING 时同步擦除快照：尺寸将变时记录变化前的客户区
  // 屏幕矩形；纯移动时快照随窗口平移（移动不产生新暴露区域）。
  // 供 FillExposedEdgesOnErase 计算"新暴露区域"。
  static void SyncEraseSnapshotOnWindowPosChanging(HWND hwnd, WINDOWPOS* pos);

  // 用当前擦除底色填充本次变化"新暴露"的客户区区域：屏幕坐标系下当前
  // 客户矩形减去快照矩形（最多四条边带），并把快照推进为当前矩形。
  //
  // 必须按屏幕坐标算差异而不是客户区右/下增长带：最大化时窗口原点同时
  // 移动（如从屏幕中部跳到全屏），旧画面停留在原屏幕位置，暴露的是
  // 上/左/右/下四侧；只填差异带可保留旧画面，整幅填充则会在 Flutter
  // 下一帧到达前把全部旧内容盖成底色，表现为最大化/还原时整屏闪色。
  // 顶层窗口与 FLUTTERVIEW 子窗口共用同一份快照：首个到达的擦除填充
  // 差异并推进快照，后续擦除差异为空、自然空操作。
  static void FillExposedEdgesOnErase(HWND hwnd, HDC hdc);

  // 单实例：已有实例激活消息 ID（RegisterWindowMessage）与窗口置前。
  //
  // 由 main.cpp（第二实例的兜底置前）与 MessageHandler（已有实例收到广播后
  // 自己抢前台）共用，GUID 字面量只落在 win32_window.cc 一处，避免漂移。
  static UINT SingleInstanceActivateMessageId();
  static const wchar_t* SingleInstanceMutexName();
  static void BringWindowToFront(HWND hwnd);

  // Return a RECT representing the bounds of the current client area.
  RECT GetClientArea();

 protected:
  // Processes and route salient window messages for mouse handling,
  // size change and DPI. Delegates handling of these to member overloads that
  // inheriting classes can handle.
  virtual LRESULT MessageHandler(HWND window,
                                 UINT const message,
                                 WPARAM const wparam,
                                 LPARAM const lparam) noexcept;

  // Called when CreateAndShow is called, allowing subclass window-related
  // setup. Subclasses should return false if setup fails.
  virtual bool OnCreate();

  // Called when Destroy is called.
  virtual void OnDestroy();

 private:
  friend class WindowClassRegistrar;

  // OS callback called by message pump. Handles the WM_NCCREATE message which
  // is passed when the non-client area is being created and enables automatic
  // non-client DPI scaling so that the non-client area automatically
  // responds to changes in DPI. All other messages are handled by
  // MessageHandler.
  static LRESULT CALLBACK WndProc(HWND const window,
                                  UINT const message,
                                  WPARAM const wparam,
                                  LPARAM const lparam) noexcept;

  // Retrieves a class instance pointer for |window|
  static Win32Window* GetThisFromHandle(HWND const window) noexcept;

  // Update the window frame's theme to match the system theme.
  static void UpdateTheme(HWND const window);

  bool quit_on_close_ = false;

  // window handle for top level window.
  HWND window_handle_ = nullptr;

  // window handle for hosted content.
  HWND child_content_ = nullptr;
};

#endif  // RUNNER_WIN32_WINDOW_H_
