#include "flutter_window.h"

#include <optional>
#include <commdlg.h>
#include <flutter/standard_method_codec.h>
#include "utils.h"

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
  account_session_channel_ = std::make_unique<dropo::AccountSessionChannel>(
      flutter_controller_->engine()->messenger());
  applications_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "dropo/application_picker",
      &flutter::StandardMethodCodec::GetInstance());
  applications_channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    if (call.method_name() != "pickExecutable") { result->NotImplemented(); return; }
    wchar_t path[32768] = {};
    OPENFILENAMEW dialog = {};
    dialog.lStructSize = sizeof(dialog);
    dialog.hwndOwner = GetHandle();
    dialog.lpstrFilter = L"Windows (*.exe)\0*.exe\0";
    dialog.lpstrFile = path;
    dialog.nMaxFile = ARRAYSIZE(path);
    dialog.Flags = OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST | OFN_NOCHANGEDIR;
    if (GetOpenFileNameW(&dialog)) {
      result->Success(flutter::EncodableValue(Utf8FromUtf16(path)));
    } else if (CommDlgExtendedError()) {
      result->Error("PICK_FAILED", "Windows file dialog failed");
    } else { result->Success(); }
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
  applications_channel_.reset();
  account_session_channel_.reset();
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
