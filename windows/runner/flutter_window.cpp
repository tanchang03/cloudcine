#include "flutter_window.h"

#include <optional>

#include "desktop_multi_window/desktop_multi_window_plugin.h"
#include "flutter/generated_plugin_registrant.h"

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

  // ⛔⛔ 这一段**不能删**：给 `desktop_multi_window` 建的**播放器子窗口**补注册插件。
  //
  // 子窗口跑的是**独立 Flutter 引擎**，插件注册是**每个引擎各一份**的 ——
  // 上面那行 `RegisterPlugins` 只覆盖了主窗口。`desktop_multi_window` 的
  // `MultiWindowManager::Create()` 建完子窗口后**只注册了它自己那一个插件**，
  // 其余插件（包括 `media_kit_video`）要由应用通过这个回调补上。
  //
  // 漏掉的实测后果（Windows 首版）：
  //   1. 播放器**只有声音没有画面**，日志里 mpv 报
  //      `vo/libmpv: No render context set.` +
  //      `Error opening/initializing the selected video_out (--vo) device.`
  //      —— 因为 `media_kit_video` 的 `VideoOutputManager` 通道在子引擎里
  //      不存在，原生 `VideoOutput`（以及它持有的 `mpv_render_context`）
  //      根本建不出来。**mpv 本体走 dart:ffi，不经插件通道**，所以
  //      「日志正常、就是不出画」——排查时极容易被误判成编解码问题。
  //   2. 所有 `cloudcine/window` 调用（setTitle / 拖窗 / 全屏）报
  //      `MissingPluginException`。
  //
  // ⚠️ 这里传进来的 `controller` 是 `flutter::FlutterViewController*`，
  // 与官方 example 的写法一致；`RegisterPlugins` 对子窗口是安全的 ——
  // `DesktopMultiWindowPluginRegisterWithRegistrar` 走 `AttachFlutterMainWindow`
  // 时会先在自己的 `windows_` 表里查到该窗口并**提前 return**（见
  // `multi_window_manager.cc`），所以不会把子窗口误登记成主窗口。
  DesktopMultiWindowSetWindowCreatedCallback([](void *controller) {
    auto *flutter_view_controller =
        reinterpret_cast<flutter::FlutterViewController *>(controller);
    auto *registry = flutter_view_controller->engine();
    RegisterPlugins(registry);
  });

  SetChildContent(flutter_controller_->view()->GetNativeWindow());

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
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
