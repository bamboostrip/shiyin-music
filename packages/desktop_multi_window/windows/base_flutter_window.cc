//
// Created by yangbin on 2022/1/27.
//

#include "base_flutter_window.h"

namespace {
void CenterRectToMonitor(LPRECT prc) {
  HMONITOR hMonitor;
  MONITORINFO mi;
  RECT rc;
  int w = prc->right - prc->left;
  int h = prc->bottom - prc->top;

  //
  // get the nearest monitor to the passed rect.
  //
  hMonitor = MonitorFromRect(prc, MONITOR_DEFAULTTONEAREST);

  //
  // get the work area or entire monitor rect.
  //
  mi.cbSize = sizeof(mi);
  GetMonitorInfo(hMonitor, &mi);

  rc = mi.rcMonitor;

  prc->left = rc.left + (rc.right - rc.left - w) / 2;
  prc->top = rc.top + (rc.bottom - rc.top - h) / 2;
  prc->right = prc->left + w;
  prc->bottom = prc->top + h;

}

std::wstring Utf16FromUtf8(const std::string &string) {
  int size_needed = MultiByteToWideChar(CP_UTF8, 0, string.c_str(), -1, nullptr, 0);
  if (size_needed == 0) {
    return {};
  }
  std::wstring wstrTo(size_needed, 0);
  int converted_length = MultiByteToWideChar(CP_UTF8, 0, string.c_str(), -1, &wstrTo[0], size_needed);
  if (converted_length == 0) {
    return {};
  }
  return wstrTo;
}

}

void BaseFlutterWindow::Center() {
  auto handle = GetWindowHandle();
  if (!handle) {
    return;
  }
  RECT rc;
  GetWindowRect(handle, &rc);
  CenterRectToMonitor(&rc);
  SetWindowPos(handle, nullptr, rc.left, rc.top, 0, 0, SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
}

void BaseFlutterWindow::SetBounds(double_t x, double_t y, double_t width, double_t height) {
  auto handle = GetWindowHandle();
  if (!handle) {
    return;
  }
  MoveWindow(handle, int32_t(x), int32_t(y),
             static_cast<int>(width),
             static_cast<int>(height),
             TRUE);
}

void BaseFlutterWindow::SetTitle(const std::string &title) {
  auto handle = GetWindowHandle();
  if (!handle) {
    return;
  }
  SetWindowText(handle, Utf16FromUtf8(title).c_str());
}

void BaseFlutterWindow::Close() {
  auto handle = GetWindowHandle();
  if (!handle) {
    return;
  }
  PostMessage(handle, WM_SYSCOMMAND, SC_CLOSE, 0);
}

void BaseFlutterWindow::Show() {
  auto handle = GetWindowHandle();
  if (!handle) {
    return;
  }
  // LOCAL PATCH (shiyin): SW_SHOW -> SW_SHOWNOACTIVATE。
  //
  // 多窗口与主窗共享同一 UI 线程/TSF 线程管理器。SW_SHOW 会激活新窗口
  // （WS_EX_NOACTIVATE 也挡不住 ShowWindow 的显式激活），桌面歌词悬浮窗
  // 一显示就把 TSF 焦点文档从主窗抢走；主窗在托盘时关掉悬浮窗，线程的
  // 输入法开/关 compartment 就再也回不来——中文输入法不能组词、只能重启
  // 进程（flutter/flutter#190042 同源）。悬浮窗没有键盘输入需求，改为
  // 显示但不激活。升级本包时必须重新移植这一处补丁。
  ShowWindow(handle, SW_SHOWNOACTIVATE);
}

void BaseFlutterWindow::Hide() {
  auto handle = GetWindowHandle();
  if (!handle) {
    return;
  }
  ShowWindow(handle, SW_HIDE);
}
