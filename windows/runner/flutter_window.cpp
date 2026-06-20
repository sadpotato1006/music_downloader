#include "flutter_window.h"

#include <flutter/standard_method_codec.h>
#include <shellapi.h>

#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <variant>

#include "desktop_lyrics_window.h"
#include "flutter/generated_plugin_registrant.h"
#include "resource.h"

namespace {

constexpr const char kDesktopLyricsChannel[] = "qingting/desktop_lyrics";
constexpr UINT kTrayMessage = WM_APP + 1;
constexpr UINT kTrayIconId = 1;
constexpr UINT kTrayOpenCommand = 40001;
constexpr UINT kTrayExitCommand = 40002;
constexpr UINT kTrayUnlockLyricsCommand = 40003;

std::wstring Utf8ToWide(const std::string& value) {
  if (value.empty()) {
    return L"";
  }
  const int size = MultiByteToWideChar(CP_UTF8, 0, value.data(),
                                       static_cast<int>(value.size()), nullptr,
                                       0);
  if (size <= 0) {
    return L"";
  }
  std::wstring result(size, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, value.data(),
                      static_cast<int>(value.size()), result.data(), size);
  return result;
}

const flutter::EncodableValue* MapValue(const flutter::EncodableMap& map,
                                        const char* key) {
  const auto it = map.find(flutter::EncodableValue(std::string(key)));
  if (it == map.end()) {
    return nullptr;
  }
  return &it->second;
}

bool BoolValue(const flutter::EncodableMap& map,
               const char* key,
               bool fallback) {
  const auto* value = MapValue(map, key);
  if (!value) {
    return fallback;
  }
  if (const auto* bool_value = std::get_if<bool>(value)) {
    return *bool_value;
  }
  return fallback;
}

double DoubleValue(const flutter::EncodableMap& map,
                   const char* key,
                   double fallback) {
  const auto* value = MapValue(map, key);
  if (!value) {
    return fallback;
  }
  if (const auto* double_value = std::get_if<double>(value)) {
    return *double_value;
  }
  if (const auto* int32_value = std::get_if<int32_t>(value)) {
    return static_cast<double>(*int32_value);
  }
  if (const auto* int64_value = std::get_if<int64_t>(value)) {
    return static_cast<double>(*int64_value);
  }
  return fallback;
}

uint32_t ColorValue(const flutter::EncodableMap& map,
                    const char* key,
                    uint32_t fallback) {
  const auto* value = MapValue(map, key);
  if (!value) {
    return fallback;
  }
  if (const auto* int32_value = std::get_if<int32_t>(value)) {
    return static_cast<uint32_t>(*int32_value);
  }
  if (const auto* int64_value = std::get_if<int64_t>(value)) {
    return static_cast<uint32_t>(*int64_value);
  }
  return fallback;
}

std::wstring StringValue(const flutter::EncodableMap& map, const char* key) {
  const auto* value = MapValue(map, key);
  if (!value) {
    return L"";
  }
  if (const auto* string_value = std::get_if<std::string>(value)) {
    return Utf8ToWide(*string_value);
  }
  return L"";
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
  AddTrayIcon();
  desktop_lyrics_window_ = std::make_unique<DesktopLyricsWindow>();
  desktop_lyrics_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), kDesktopLyricsChannel,
          &flutter::StandardMethodCodec::GetInstance());
  desktop_lyrics_window_->SetPositionChangedCallback(
      [this](double horizontal_position, double vertical_position) {
        if (!desktop_lyrics_channel_) {
          return;
        }
        flutter::EncodableMap arguments;
        arguments[flutter::EncodableValue("horizontalPosition")] =
            flutter::EncodableValue(horizontal_position);
        arguments[flutter::EncodableValue("verticalPosition")] =
            flutter::EncodableValue(vertical_position);
        desktop_lyrics_channel_->InvokeMethod(
            "positionChanged",
            std::make_unique<flutter::EncodableValue>(arguments));
      });
  desktop_lyrics_window_->SetLockChangedCallback([this](bool locked) {
    desktop_lyrics_locked_ = locked;
    if (!desktop_lyrics_channel_) {
      return;
    }
    flutter::EncodableMap arguments;
    arguments[flutter::EncodableValue("locked")] =
        flutter::EncodableValue(locked);
    desktop_lyrics_channel_->InvokeMethod(
        "lockChanged", std::make_unique<flutter::EncodableValue>(arguments));
    if (locked) {
      ShowTrayBalloon(
          L"\u684C\u9762\u6B4C\u8BCD\u5DF2\u9501\u5B9A",
          L"\u53EF\u5728\u8F6F\u4EF6\u6B4C\u8BCD\u8BBE\u7F6E\u4E2D\u5173\u95ED\u9501\u5B9A\uFF0C\u6216\u53F3\u952E\u6258\u76D8\u56FE\u6807\u9009\u62E9\u6B4C\u8BCD\u89E3\u9501\u3002");
    }
  });
  desktop_lyrics_channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        const auto& method = call.method_name();
        if (method == "update") {
          const auto* arguments = call.arguments();
          const auto* map =
              arguments
                  ? std::get_if<flutter::EncodableMap>(arguments)
                  : nullptr;
          if (!map) {
            result->Error("bad_args", "Expected a settings map.");
            return;
          }
          desktop_lyrics_locked_ = BoolValue(*map, "locked", false);
          desktop_lyrics_window_->Update(
              BoolValue(*map, "enabled", false), StringValue(*map, "text"),
              DoubleValue(*map, "fontSize", 22.0),
              ColorValue(*map, "colorValue", 0xFF4AA66A),
              DoubleValue(*map, "horizontalPosition", 0.5),
              DoubleValue(*map, "verticalPosition", 0.78),
              DoubleValue(*map, "backgroundOpacity", 0.12),
              desktop_lyrics_locked_);
          result->Success(flutter::EncodableValue(true));
          return;
        }
        if (method == "hide") {
          desktop_lyrics_window_->Hide();
          result->Success();
          return;
        }
        if (method == "isOverlayPermissionGranted") {
          result->Success(flutter::EncodableValue(true));
          return;
        }
        if (method == "openOverlayPermissionSettings") {
          result->Success();
          return;
        }
        result->NotImplemented();
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
  RemoveTrayIcon();

  if (desktop_lyrics_window_) {
    desktop_lyrics_window_->Hide();
  }
  desktop_lyrics_channel_ = nullptr;
  desktop_lyrics_window_ = nullptr;

  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (message == WM_CLOSE && !allow_window_close_) {
    ShowWindow(hwnd, SW_HIDE);
    return 0;
  }
  if (message == kTrayMessage) {
    if (lparam == WM_LBUTTONUP || lparam == WM_LBUTTONDBLCLK) {
      ShowMainWindow();
      return 0;
    }
    if (lparam == WM_RBUTTONUP || lparam == WM_CONTEXTMENU) {
      ShowTrayMenu();
      return 0;
    }
  }
  if (message == WM_COMMAND) {
    switch (LOWORD(wparam)) {
      case kTrayOpenCommand:
        ShowMainWindow();
        return 0;
      case kTrayExitCommand:
        ExitFromTray();
        return 0;
      case kTrayUnlockLyricsCommand:
        UnlockDesktopLyricsFromTray();
        return 0;
    }
  }

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

void FlutterWindow::AddTrayIcon() {
  if (tray_icon_added_ || !GetHandle()) {
    return;
  }
  NOTIFYICONDATAW data{};
  data.cbSize = sizeof(data);
  data.hWnd = GetHandle();
  data.uID = kTrayIconId;
  data.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
  data.uCallbackMessage = kTrayMessage;
  data.hIcon = LoadIcon(GetModuleHandle(nullptr), MAKEINTRESOURCE(IDI_APP_ICON));
  wcscpy_s(data.szTip, L"QingTing");
  tray_icon_added_ = Shell_NotifyIconW(NIM_ADD, &data) == TRUE;
}

void FlutterWindow::RemoveTrayIcon() {
  if (!tray_icon_added_ || !GetHandle()) {
    return;
  }
  NOTIFYICONDATAW data{};
  data.cbSize = sizeof(data);
  data.hWnd = GetHandle();
  data.uID = kTrayIconId;
  Shell_NotifyIconW(NIM_DELETE, &data);
  tray_icon_added_ = false;
}

void FlutterWindow::ShowMainWindow() {
  if (!GetHandle()) {
    return;
  }
  ShowWindow(GetHandle(), SW_SHOWNORMAL);
  SetForegroundWindow(GetHandle());
}

void FlutterWindow::ShowTrayMenu() {
  if (!GetHandle()) {
    return;
  }
  POINT point{};
  GetCursorPos(&point);
  HMENU menu = CreatePopupMenu();
  AppendMenuW(menu, MF_STRING, kTrayOpenCommand, L"\u6253\u5F00\u9752\u542C");
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(menu, MF_STRING | (desktop_lyrics_locked_ ? 0 : MF_GRAYED),
              kTrayUnlockLyricsCommand,
              L"\u6B4C\u8BCD\u89E3\u9501");
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(menu, MF_STRING, kTrayExitCommand, L"\u9000\u51FA");
  SetForegroundWindow(GetHandle());
  TrackPopupMenu(menu, TPM_RIGHTBUTTON | TPM_BOTTOMALIGN | TPM_LEFTALIGN,
                 point.x, point.y, 0, GetHandle(), nullptr);
  DestroyMenu(menu);
}

void FlutterWindow::UnlockDesktopLyricsFromTray() {
  desktop_lyrics_locked_ = false;
  if (desktop_lyrics_window_) {
    desktop_lyrics_window_->SetLocked(false);
  }
  if (desktop_lyrics_channel_) {
    flutter::EncodableMap arguments;
    arguments[flutter::EncodableValue("locked")] =
        flutter::EncodableValue(false);
    desktop_lyrics_channel_->InvokeMethod(
        "lockChanged", std::make_unique<flutter::EncodableValue>(arguments));
  }
  ShowTrayBalloon(L"\u684C\u9762\u6B4C\u8BCD\u5DF2\u89E3\u9501",
                  L"\u73B0\u5728\u53EF\u4EE5\u62D6\u52A8\u6B4C\u8BCD\u8C03\u6574\u4F4D\u7F6E\u3002");
}

void FlutterWindow::ShowTrayBalloon(const wchar_t* title,
                                    const wchar_t* message) {
  if (!tray_icon_added_ || !GetHandle()) {
    return;
  }
  NOTIFYICONDATAW data{};
  data.cbSize = sizeof(data);
  data.hWnd = GetHandle();
  data.uID = kTrayIconId;
  data.uFlags = NIF_INFO;
  wcscpy_s(data.szInfoTitle, title);
  wcscpy_s(data.szInfo, message);
  data.dwInfoFlags = NIIF_INFO;
  Shell_NotifyIconW(NIM_MODIFY, &data);
}

void FlutterWindow::ExitFromTray() {
  allow_window_close_ = true;
  RemoveTrayIcon();
  if (desktop_lyrics_window_) {
    desktop_lyrics_window_->Hide();
  }
  if (GetHandle()) {
    DestroyWindow(GetHandle());
  }
}
