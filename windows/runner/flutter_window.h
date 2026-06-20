#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <memory>

#include "win32_window.h"

class DesktopLyricsWindow;

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
  void AddTrayIcon();
  void RemoveTrayIcon();
  void ShowMainWindow();
  void ShowTrayMenu();
  void UnlockDesktopLyricsFromTray();
  void ShowTrayBalloon(const wchar_t* title, const wchar_t* message);
  void ExitFromTray();

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  std::unique_ptr<DesktopLyricsWindow> desktop_lyrics_window_;

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      desktop_lyrics_channel_;

  bool tray_icon_added_ = false;
  bool allow_window_close_ = false;
  bool desktop_lyrics_locked_ = false;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
