#include "window_state.h"

#include <algorithm>
#include <string>
#include <vector>

namespace {

constexpr const wchar_t kAppDirectory[] = L"QingTing";
constexpr const wchar_t kStateFileName[] = L"window_state.ini";
constexpr const wchar_t kWindowSection[] = L"Window";
constexpr const wchar_t kWidthKey[] = L"Width";
constexpr const wchar_t kHeightKey[] = L"Height";
constexpr unsigned int kMinimumWidth = 640;
constexpr unsigned int kMinimumHeight = 480;

std::wstring WindowStateFilePath() {
  const DWORD required = GetEnvironmentVariableW(L"APPDATA", nullptr, 0);
  if (required == 0) {
    return L"";
  }

  std::vector<wchar_t> buffer(required);
  if (GetEnvironmentVariableW(L"APPDATA", buffer.data(), required) == 0) {
    return L"";
  }

  std::wstring directory(buffer.data());
  if (!directory.empty() && directory.back() != L'\\') {
    directory.push_back(L'\\');
  }
  directory.append(kAppDirectory);
  if (!CreateDirectoryW(directory.c_str(), nullptr) &&
      GetLastError() != ERROR_ALREADY_EXISTS) {
    return L"";
  }

  directory.push_back(L'\\');
  directory.append(kStateFileName);
  return directory;
}

window_state::WindowSize ClampWindowSize(unsigned int width,
                                         unsigned int height) {
  RECT work_area{};
  if (!SystemParametersInfoW(SPI_GETWORKAREA, 0, &work_area, 0)) {
    return {std::max(kMinimumWidth, width), std::max(kMinimumHeight, height)};
  }

  UINT dpi = GetDpiForSystem();
  if (dpi == 0) {
    dpi = 96;
  }
  const unsigned int maximum_width = std::max(
      kMinimumWidth,
      static_cast<unsigned int>(
          MulDiv(work_area.right - work_area.left, 96, static_cast<int>(dpi))));
  const unsigned int maximum_height = std::max(
      kMinimumHeight,
      static_cast<unsigned int>(
          MulDiv(work_area.bottom - work_area.top, 96, static_cast<int>(dpi))));
  return {std::clamp(width, kMinimumWidth, maximum_width),
          std::clamp(height, kMinimumHeight, maximum_height)};
}

}  // namespace

namespace window_state {

WindowSize LoadWindowSize(unsigned int default_width,
                          unsigned int default_height) {
  const std::wstring path = WindowStateFilePath();
  if (path.empty()) {
    return ClampWindowSize(default_width, default_height);
  }

  const unsigned int width = GetPrivateProfileIntW(kWindowSection, kWidthKey,
                                                   default_width, path.c_str());
  const unsigned int height = GetPrivateProfileIntW(
      kWindowSection, kHeightKey, default_height, path.c_str());
  return ClampWindowSize(width, height);
}

void SaveWindowSize(HWND window) {
  if (!window) {
    return;
  }

  WINDOWPLACEMENT placement{};
  placement.length = sizeof(placement);
  if (!GetWindowPlacement(window, &placement)) {
    return;
  }

  const RECT &bounds = placement.rcNormalPosition;
  UINT dpi = GetDpiForWindow(window);
  if (dpi == 0) {
    dpi = 96;
  }
  const int pixel_width = bounds.right - bounds.left;
  const int pixel_height = bounds.bottom - bounds.top;
  if (pixel_width <= 0 || pixel_height <= 0) {
    return;
  }

  const WindowSize size = ClampWindowSize(
      static_cast<unsigned int>(MulDiv(pixel_width, 96, static_cast<int>(dpi))),
      static_cast<unsigned int>(
          MulDiv(pixel_height, 96, static_cast<int>(dpi))));
  const std::wstring path = WindowStateFilePath();
  if (path.empty()) {
    return;
  }

  const std::wstring width = std::to_wstring(size.width);
  const std::wstring height = std::to_wstring(size.height);
  WritePrivateProfileStringW(kWindowSection, kWidthKey, width.c_str(),
                             path.c_str());
  WritePrivateProfileStringW(kWindowSection, kHeightKey, height.c_str(),
                             path.c_str());
}

}  // namespace window_state