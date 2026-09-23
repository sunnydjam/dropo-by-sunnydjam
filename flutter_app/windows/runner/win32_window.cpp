#include "win32_window.h"

#include <dwmapi.h>
#include <flutter_windows.h>

#include "resource.h"

namespace {

/// Window attribute that enables dark mode window decorations.
///
/// Redefined in case the developer's machine has a Windows SDK older than
/// version 10.0.22000.0.
/// See: https://docs.microsoft.com/windows/win32/api/dwmapi/ne-dwmapi-dwmwindowattribute
#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
#define DWMWA_USE_IMMERSIVE_DARK_MODE 20
#endif

constexpr const wchar_t kWindowClassName[] = L"FLUTTER_RUNNER_WIN32_WINDOW";

/// Registry key for app theme preference.
///
/// A value of 0 indicates apps should use dark mode. A non-zero or missing
/// value indicates apps should use light mode.
constexpr const wchar_t kGetPreferredBrightnessRegKey[] =
  L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize";
constexpr const wchar_t kGetPreferredBrightnessRegValue[] = L"AppsUseLightTheme";

// UI-only per-user data, deliberately separate from VPN profiles/settings.
constexpr const wchar_t kWindowPlacementRegKey[] = L"Software\\DropoVPN\\Window";
constexpr const wchar_t kWindowPlacementRegValue[] = L"NormalPlacementV1";

namespace geometry = dropo::window_geometry;

// The number of Win32Window objects that currently exist.
static int g_active_window_count = 0;

using EnableNonClientDpiScaling = BOOL __stdcall(HWND hwnd);

geometry::Rect ToGeometryRect(const RECT& rect) {
  return {static_cast<int>(rect.left), static_cast<int>(rect.top),
          static_cast<int>(rect.right), static_cast<int>(rect.bottom)};
}

RECT ToNativeRect(const geometry::Rect& rect) {
  return {rect.left, rect.top, rect.right, rect.bottom};
}

UINT MonitorDpi(HMONITOR monitor) {
  const UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
  return dpi == 0 ? 96 : dpi;
}

UINT WindowDpi(HWND window) {
  using GetWindowDpi = UINT(WINAPI*)(HWND);
  const auto get_window_dpi = reinterpret_cast<GetWindowDpi>(GetProcAddress(
      GetModuleHandleW(L"user32.dll"), "GetDpiForWindow"));
  if (get_window_dpi != nullptr) {
    const UINT dpi = get_window_dpi(window);
    if (dpi != 0) {
      return dpi;
    }
  }
  return MonitorDpi(MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST));
}

bool ReadPlacement(geometry::SavedPlacement* saved) {
  DWORD size = sizeof(*saved);
  const LSTATUS result = RegGetValueW(
      HKEY_CURRENT_USER, kWindowPlacementRegKey, kWindowPlacementRegValue,
      RRF_RT_REG_BINARY, nullptr, saved, &size);
  return result == ERROR_SUCCESS && size == sizeof(*saved) &&
         geometry::ValidPlacement(*saved);
}

RECT ClampToMonitorWorkArea(const RECT& rect) {
  MONITORINFO info{sizeof(info)};
  const HMONITOR monitor = MonitorFromRect(&rect, MONITOR_DEFAULTTONEAREST);
  if (!GetMonitorInfo(monitor, &info)) {
    return rect;
  }
  return ToNativeRect(geometry::ClampToWorkArea(ToGeometryRect(rect),
                                               ToGeometryRect(info.rcWork)));
}

RECT ClientWindowBounds(int left, int top, int width, int height, UINT dpi) {
  RECT frame{0, 0, geometry::ScaleForDpi(width, dpi),
             geometry::ScaleForDpi(height, dpi)};
  using AdjustForDpi = BOOL(WINAPI*)(LPRECT, DWORD, BOOL, DWORD, UINT);
  const auto adjust_for_dpi = reinterpret_cast<AdjustForDpi>(GetProcAddress(
      GetModuleHandleW(L"user32.dll"), "AdjustWindowRectExForDpi"));
  if (adjust_for_dpi != nullptr) {
    adjust_for_dpi(&frame, WS_OVERLAPPEDWINDOW, FALSE, 0, dpi);
  } else {
    // Compatibility with Windows versions predating the per-monitor API.
    AdjustWindowRectEx(&frame, WS_OVERLAPPEDWINDOW, FALSE, 0);
  }
  return {left, top, left + frame.right - frame.left,
          top + frame.bottom - frame.top};
}

// Dynamically loads the |EnableNonClientDpiScaling| from the User32 module.
// This API is only needed for PerMonitor V1 awareness mode.
void EnableFullDpiSupportIfAvailable(HWND hwnd) {
  HMODULE user32_module = LoadLibraryA("User32.dll");
  if (!user32_module) {
    return;
  }
  auto enable_non_client_dpi_scaling =
      reinterpret_cast<EnableNonClientDpiScaling*>(
          GetProcAddress(user32_module, "EnableNonClientDpiScaling"));
  if (enable_non_client_dpi_scaling != nullptr) {
    enable_non_client_dpi_scaling(hwnd);
  }
  FreeLibrary(user32_module);
}

}  // namespace

// Manages the Win32Window's window class registration.
class WindowClassRegistrar {
 public:
  ~WindowClassRegistrar() = default;

  // Returns the singleton registrar instance.
  static WindowClassRegistrar* GetInstance() {
    if (!instance_) {
      instance_ = new WindowClassRegistrar();
    }
    return instance_;
  }

  // Returns the name of the window class, registering the class if it hasn't
  // previously been registered.
  const wchar_t* GetWindowClass();

  // Unregisters the window class. Should only be called if there are no
  // instances of the window.
  void UnregisterWindowClass();

 private:
  WindowClassRegistrar() = default;

  static WindowClassRegistrar* instance_;

  bool class_registered_ = false;
};

WindowClassRegistrar* WindowClassRegistrar::instance_ = nullptr;

const wchar_t* WindowClassRegistrar::GetWindowClass() {
  if (!class_registered_) {
    WNDCLASS window_class{};
    window_class.hCursor = LoadCursor(nullptr, IDC_ARROW);
    window_class.lpszClassName = kWindowClassName;
    window_class.style = CS_HREDRAW | CS_VREDRAW;
    window_class.cbClsExtra = 0;
    window_class.cbWndExtra = 0;
    window_class.hInstance = GetModuleHandle(nullptr);
    window_class.hIcon =
        LoadIcon(window_class.hInstance, MAKEINTRESOURCE(IDI_APP_ICON));
    window_class.hbrBackground = 0;
    window_class.lpszMenuName = nullptr;
    window_class.lpfnWndProc = Win32Window::WndProc;
    RegisterClass(&window_class);
    class_registered_ = true;
  }
  return kWindowClassName;
}

void WindowClassRegistrar::UnregisterWindowClass() {
  UnregisterClass(kWindowClassName, nullptr);
  class_registered_ = false;
}

Win32Window::Win32Window() {
  ++g_active_window_count;
}

Win32Window::~Win32Window() {
  --g_active_window_count;
  Destroy();
}

bool Win32Window::Create(const std::wstring& title,
                         const Point& origin,
                         const Size& size) {
  Destroy();

  const wchar_t* window_class =
      WindowClassRegistrar::GetInstance()->GetWindowClass();

  const POINT target_point = {static_cast<LONG>(origin.x),
                              static_cast<LONG>(origin.y)};
  const HMONITOR default_monitor =
      MonitorFromPoint(target_point, MONITOR_DEFAULTTONEAREST);
  const UINT default_dpi = MonitorDpi(default_monitor);
  RECT bounds = ClientWindowBounds(
      geometry::ScaleForDpi(origin.x, default_dpi),
      geometry::ScaleForDpi(origin.y, default_dpi),
      static_cast<int>(size.width), static_cast<int>(size.height), default_dpi);

  geometry::SavedPlacement saved{};
  if (ReadPlacement(&saved)) {
    const RECT normal_bounds = ToNativeRect(saved.normal_bounds);
    const HMONITOR monitor =
        MonitorFromRect(&normal_bounds, MONITOR_DEFAULTTONEAREST);
    bounds = ClientWindowBounds(saved.normal_bounds.left,
                                saved.normal_bounds.top, saved.client_width,
                                saved.client_height, MonitorDpi(monitor));
  }
  bounds = ClampToMonitorWorkArea(bounds);

  HWND window = CreateWindow(
      window_class, title.c_str(), WS_OVERLAPPEDWINDOW,
      bounds.left, bounds.top, bounds.right - bounds.left,
      bounds.bottom - bounds.top,
      nullptr, nullptr, GetModuleHandle(nullptr), this);

  if (!window) {
    return false;
  }

  UpdateTheme(window);
  RememberNormalPlacement(window);

  return OnCreate();
}

bool Win32Window::Show() {
  return ShowWindow(window_handle_, SW_SHOWNORMAL);
}

// static
LRESULT CALLBACK Win32Window::WndProc(HWND const window,
                                      UINT const message,
                                      WPARAM const wparam,
                                      LPARAM const lparam) noexcept {
  if (message == WM_NCCREATE) {
    auto window_struct = reinterpret_cast<CREATESTRUCT*>(lparam);
    SetWindowLongPtr(window, GWLP_USERDATA,
                     reinterpret_cast<LONG_PTR>(window_struct->lpCreateParams));

    auto that = static_cast<Win32Window*>(window_struct->lpCreateParams);
    EnableFullDpiSupportIfAvailable(window);
    that->window_handle_ = window;
  } else if (Win32Window* that = GetThisFromHandle(window)) {
    that->ObservePlacement(window, message, wparam);
    return that->MessageHandler(window, message, wparam, lparam);
  }

  return DefWindowProc(window, message, wparam, lparam);
}

LRESULT
Win32Window::MessageHandler(HWND hwnd,
                            UINT const message,
                            WPARAM const wparam,
                            LPARAM const lparam) noexcept {
  switch (message) {
    case WM_DESTROY:
      window_handle_ = nullptr;
      Destroy();
      if (quit_on_close_) {
        PostQuitMessage(0);
      }
      return 0;

    case WM_DPICHANGED: {
      auto newRectSize = reinterpret_cast<RECT*>(lparam);
      const RECT bounds = ClampToMonitorWorkArea(*newRectSize);
      SetWindowPos(hwnd, nullptr, bounds.left, bounds.top,
                   bounds.right - bounds.left, bounds.bottom - bounds.top,
                   SWP_NOZORDER | SWP_NOACTIVATE);
      RememberNormalPlacement(hwnd);
      SavePlacement();

      return 0;
    }
    case WM_DISPLAYCHANGE:
      needs_placement_constraint_ = true;
      ConstrainToWorkArea(hwnd);
      break;

    case WM_SETTINGCHANGE:
      if (wparam == SPI_SETWORKAREA) {
        needs_placement_constraint_ = true;
        ConstrainToWorkArea(hwnd);
      }
      break;
    case WM_SIZE: {
      if (wparam == SIZE_RESTORED && needs_placement_constraint_) {
        ConstrainToWorkArea(hwnd);
      }
      RECT rect = GetClientArea();
      if (child_content_ != nullptr) {
        // Size and position the child window.
        MoveWindow(child_content_, rect.left, rect.top, rect.right - rect.left,
                   rect.bottom - rect.top, TRUE);
      }
      return 0;
    }

    case WM_ACTIVATE:
      if (child_content_ != nullptr) {
        SetFocus(child_content_);
      }
      return 0;

    case WM_DWMCOLORIZATIONCOLORCHANGED:
      UpdateTheme(hwnd);
      return 0;
  }

  return DefWindowProc(window_handle_, message, wparam, lparam);
}

void Win32Window::ObservePlacement(HWND window, UINT message, WPARAM wparam) {
  switch (message) {
    case WM_WINDOWPOSCHANGED:
      RememberNormalPlacement(window);
      break;
    case WM_EXITSIZEMOVE:
    case WM_CLOSE:
      RememberNormalPlacement(window);
      SavePlacement();
      break;
    case WM_SHOWWINDOW:
      if (wparam == FALSE) {
        RememberNormalPlacement(window);
        SavePlacement();
      }
      break;
    case WM_DESTROY:
      SavePlacement();
      break;
  }
}

void Win32Window::RememberNormalPlacement(HWND window) {
  // Minimize/maximize must not overwrite the user's normal resize choice or
  // persist Windows' offscreen minimized coordinates (commonly -32000).
  if (IsIconic(window) || IsZoomed(window)) {
    return;
  }
  RECT bounds{};
  RECT client{};
  if (!GetWindowRect(window, &bounds) || !GetClientRect(window, &client)) {
    return;
  }
  const UINT dpi = WindowDpi(window);
  const geometry::SavedPlacement saved{
      geometry::kPlacementVersion, ToGeometryRect(bounds),
      geometry::LogicalPixels(static_cast<int>(client.right - client.left), dpi),
      geometry::LogicalPixels(static_cast<int>(client.bottom - client.top), dpi)};
  if (geometry::ValidPlacement(saved)) {
    normal_placement_ = saved;
    has_normal_placement_ = true;
  }
}

void Win32Window::SavePlacement() const {
  if (!has_normal_placement_) {
    return;
  }
  // A denied/roaming-profile registry write must never prevent use or exit.
  RegSetKeyValueW(HKEY_CURRENT_USER, kWindowPlacementRegKey,
                  kWindowPlacementRegValue, REG_BINARY, &normal_placement_,
                  sizeof(normal_placement_));
}

void Win32Window::ConstrainToWorkArea(HWND window) {
  if (constraining_placement_ || IsIconic(window) || IsZoomed(window)) {
    return;
  }
  RECT current{};
  if (!GetWindowRect(window, &current)) {
    return;
  }
  needs_placement_constraint_ = false;
  const RECT bounds = ClampToMonitorWorkArea(current);
  if (!EqualRect(&bounds, &current)) {
    constraining_placement_ = true;
    SetWindowPos(window, nullptr, bounds.left, bounds.top,
                 bounds.right - bounds.left, bounds.bottom - bounds.top,
                 SWP_NOZORDER | SWP_NOACTIVATE);
    constraining_placement_ = false;
    RememberNormalPlacement(window);
    SavePlacement();
  }
}

void Win32Window::Destroy() {
  OnDestroy();

  if (window_handle_) {
    DestroyWindow(window_handle_);
    window_handle_ = nullptr;
  }
  if (g_active_window_count == 0) {
    WindowClassRegistrar::GetInstance()->UnregisterWindowClass();
  }
}

Win32Window* Win32Window::GetThisFromHandle(HWND const window) noexcept {
  return reinterpret_cast<Win32Window*>(
      GetWindowLongPtr(window, GWLP_USERDATA));
}

void Win32Window::SetChildContent(HWND content) {
  child_content_ = content;
  SetParent(content, window_handle_);
  RECT frame = GetClientArea();

  MoveWindow(content, frame.left, frame.top, frame.right - frame.left,
             frame.bottom - frame.top, true);

  SetFocus(child_content_);
}

RECT Win32Window::GetClientArea() {
  RECT frame;
  GetClientRect(window_handle_, &frame);
  return frame;
}

HWND Win32Window::GetHandle() {
  return window_handle_;
}

void Win32Window::SetQuitOnClose(bool quit_on_close) {
  quit_on_close_ = quit_on_close;
}

bool Win32Window::OnCreate() {
  // No-op; provided for subclasses.
  return true;
}

void Win32Window::OnDestroy() {
  // No-op; provided for subclasses.
}

void Win32Window::UpdateTheme(HWND const window) {
  DWORD light_mode;
  DWORD light_mode_size = sizeof(light_mode);
  LSTATUS result = RegGetValue(HKEY_CURRENT_USER, kGetPreferredBrightnessRegKey,
                               kGetPreferredBrightnessRegValue,
                               RRF_RT_REG_DWORD, nullptr, &light_mode,
                               &light_mode_size);

  if (result == ERROR_SUCCESS) {
    BOOL enable_dark_mode = light_mode == 0;
    DwmSetWindowAttribute(window, DWMWA_USE_IMMERSIVE_DARK_MODE,
                          &enable_dark_mode, sizeof(enable_dark_mode));
  }
}
