#ifndef RUNNER_DESKTOP_LYRICS_WINDOW_H_
#define RUNNER_DESKTOP_LYRICS_WINDOW_H_

#include <windows.h>

#include <cstdint>
#include <functional>
#include <string>

class DesktopLyricsWindow {
 public:
  using PositionChangedCallback = std::function<void(double, double)>;
  using LockChangedCallback = std::function<void(bool)>;

  DesktopLyricsWindow();
  ~DesktopLyricsWindow();

  void Update(bool enabled,
              const std::wstring& text,
              double font_size,
              uint32_t color_value,
              double horizontal_position,
              double vertical_position,
              double background_opacity,
              bool locked);
  void Hide();
  void SetLocked(bool locked);
  void SetPositionChangedCallback(PositionChangedCallback callback);
  void SetLockChangedCallback(LockChangedCallback callback);

 private:
  bool EnsureWindow();
  void Render();
  void ApplyLockedWindowStyle();
  void StartMouseLeaveTracking();
  bool IsPointInLockButton(POINT point) const;
  void LockFromButton();
  void BeginDrag();
  void ContinueDrag();
  void EndDrag();

  static ATOM RegisterWindowClass();
  static LRESULT CALLBACK WindowProc(HWND hwnd,
                                     UINT message,
                                     WPARAM wparam,
                                     LPARAM lparam);

  HWND window_ = nullptr;
  ULONG_PTR gdiplus_token_ = 0;
  std::wstring text_;
  double font_size_ = 22.0;
  uint32_t color_value_ = 0xFF4AA66A;
  double horizontal_position_ = 0.5;
  double vertical_position_ = 0.78;
  double background_opacity_ = 0.12;
  bool locked_ = false;
  bool hover_controls_ = false;
  bool tracking_mouse_leave_ = false;
  bool lock_button_pressed_ = false;
  bool dragging_ = false;
  RECT lock_button_rect_{};
  POINT drag_start_cursor_{};
  RECT drag_start_window_rect_{};
  PositionChangedCallback position_changed_callback_;
  LockChangedCallback lock_changed_callback_;
};

#endif  // RUNNER_DESKTOP_LYRICS_WINDOW_H_
