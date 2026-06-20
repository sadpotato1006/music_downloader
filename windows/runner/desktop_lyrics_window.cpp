#include "desktop_lyrics_window.h"

#include <gdiplus.h>
#include <windowsx.h>

#include <algorithm>
#include <cmath>
#include <memory>
#include <utility>

namespace {

constexpr const wchar_t kDesktopLyricsWindowClass[] =
    L"QingTingDesktopLyricsWindow";
constexpr UINT_PTR kHideControlsTimerId = 1;
constexpr UINT kHideControlsDelayMs = 700;

double ClampDouble(double value, double min_value, double max_value) {
  return std::clamp(value, min_value, max_value);
}

int ClampInt(int value, int min_value, int max_value) {
  return std::clamp(value, min_value, max_value);
}

void AddRoundedRectangle(Gdiplus::GraphicsPath& path,
                         const Gdiplus::RectF& rect,
                         float radius) {
  const float diameter = radius * 2.0f;
  path.AddArc(rect.X, rect.Y, diameter, diameter, 180.0f, 90.0f);
  path.AddArc(rect.GetRight() - diameter, rect.Y, diameter, diameter, 270.0f,
              90.0f);
  path.AddArc(rect.GetRight() - diameter, rect.GetBottom() - diameter,
              diameter, diameter, 0.0f, 90.0f);
  path.AddArc(rect.X, rect.GetBottom() - diameter, diameter, diameter, 90.0f,
              90.0f);
  path.CloseFigure();
}

void DrawLockIcon(Gdiplus::Graphics& graphics,
                  const Gdiplus::RectF& rect,
                  const Gdiplus::Color& color,
                  float scale) {
  Gdiplus::Pen pen(color, std::max(1.6f, 1.8f * scale));
  Gdiplus::SolidBrush brush(color);
  const float body_width = rect.Width * 0.42f;
  const float body_height = rect.Height * 0.32f;
  const float body_x = rect.X + (rect.Width - body_width) / 2.0f;
  const float body_y = rect.Y + rect.Height * 0.48f;
  Gdiplus::RectF body(body_x, body_y, body_width, body_height);
  graphics.FillRectangle(&brush, body);
  Gdiplus::RectF shackle(body_x + body_width * 0.12f,
                         rect.Y + rect.Height * 0.24f,
                         body_width * 0.76f, rect.Height * 0.42f);
  graphics.DrawArc(&pen, shackle, 200.0f, 140.0f);
}

std::unique_ptr<Gdiplus::FontFamily> PreferredFontFamily() {
  auto family = std::make_unique<Gdiplus::FontFamily>(L"Microsoft YaHei UI");
  if (family->GetLastStatus() == Gdiplus::Ok) {
    return family;
  }
  family = std::make_unique<Gdiplus::FontFamily>(L"Microsoft YaHei");
  if (family->GetLastStatus() == Gdiplus::Ok) {
    return family;
  }
  return std::make_unique<Gdiplus::FontFamily>(L"Segoe UI");
}

}  // namespace

DesktopLyricsWindow::DesktopLyricsWindow() {
  Gdiplus::GdiplusStartupInput input;
  Gdiplus::GdiplusStartup(&gdiplus_token_, &input, nullptr);
}

DesktopLyricsWindow::~DesktopLyricsWindow() {
  Hide();
  if (window_) {
    DestroyWindow(window_);
    window_ = nullptr;
  }
  if (gdiplus_token_ != 0) {
    Gdiplus::GdiplusShutdown(gdiplus_token_);
    gdiplus_token_ = 0;
  }
}

void DesktopLyricsWindow::Update(bool enabled,
                                 const std::wstring& text,
                                 double font_size,
                                 uint32_t color_value,
                                 double horizontal_position,
                                 double vertical_position,
                                 double background_opacity,
                                 bool locked) {
  if (!enabled || text.empty()) {
    Hide();
    return;
  }

  text_ = text;
  font_size_ = ClampDouble(font_size, 14.0, 72.0);
  color_value_ = color_value;
  horizontal_position_ = ClampDouble(horizontal_position, 0.0, 1.0);
  vertical_position_ = ClampDouble(vertical_position, 0.0, 1.0);
  background_opacity_ = ClampDouble(background_opacity, 0.0, 0.85);
  locked_ = locked;
  if (locked_) {
    hover_controls_ = false;
    lock_button_pressed_ = false;
    dragging_ = false;
  }

  if (!EnsureWindow()) {
    return;
  }
  ApplyLockedWindowStyle();
  Render();
}

void DesktopLyricsWindow::Hide() {
  if (window_) {
    KillTimer(window_, kHideControlsTimerId);
    ShowWindow(window_, SW_HIDE);
  }
  hover_controls_ = false;
  lock_button_pressed_ = false;
  dragging_ = false;
}

void DesktopLyricsWindow::SetLocked(bool locked) {
  if (locked_ == locked) {
    return;
  }
  locked_ = locked;
  if (locked_) {
    if (window_) {
      KillTimer(window_, kHideControlsTimerId);
    }
    hover_controls_ = false;
    lock_button_pressed_ = false;
    dragging_ = false;
    if (GetCapture() == window_) {
      ReleaseCapture();
    }
  }
  ApplyLockedWindowStyle();
  Render();
}

void DesktopLyricsWindow::SetPositionChangedCallback(
    PositionChangedCallback callback) {
  position_changed_callback_ = std::move(callback);
}

void DesktopLyricsWindow::SetLockChangedCallback(LockChangedCallback callback) {
  lock_changed_callback_ = std::move(callback);
}

bool DesktopLyricsWindow::EnsureWindow() {
  if (window_) {
    return true;
  }
  if (RegisterWindowClass() == 0) {
    return false;
  }

  window_ = CreateWindowExW(
      WS_EX_LAYERED | WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
      kDesktopLyricsWindowClass, L"QingTing Desktop Lyrics", WS_POPUP, 0, 0, 1,
      1, nullptr, nullptr, GetModuleHandle(nullptr), this);
  return window_ != nullptr;
}

void DesktopLyricsWindow::ApplyLockedWindowStyle() {
  if (!window_) {
    return;
  }
  LONG_PTR style = GetWindowLongPtrW(window_, GWL_EXSTYLE);
  if (locked_) {
    style |= WS_EX_TRANSPARENT;
  } else {
    style &= ~WS_EX_TRANSPARENT;
  }
  SetWindowLongPtrW(window_, GWL_EXSTYLE, style);
  SetWindowPos(window_, nullptr, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE |
                   SWP_FRAMECHANGED);
}

void DesktopLyricsWindow::StartMouseLeaveTracking() {
  if (!window_ || tracking_mouse_leave_) {
    return;
  }
  TRACKMOUSEEVENT event{};
  event.cbSize = sizeof(TRACKMOUSEEVENT);
  event.dwFlags = TME_LEAVE;
  event.hwndTrack = window_;
  tracking_mouse_leave_ = TrackMouseEvent(&event) == TRUE;
}

bool DesktopLyricsWindow::IsPointInLockButton(POINT point) const {
  return !locked_ && hover_controls_ && PtInRect(&lock_button_rect_, point);
}

void DesktopLyricsWindow::LockFromButton() {
  SetLocked(true);
  if (lock_changed_callback_) {
    lock_changed_callback_(true);
  }
}

void DesktopLyricsWindow::BeginDrag() {
  if (!window_ || locked_) {
    return;
  }
  dragging_ = true;
  GetCursorPos(&drag_start_cursor_);
  GetWindowRect(window_, &drag_start_window_rect_);
  SetCapture(window_);
}

void DesktopLyricsWindow::ContinueDrag() {
  if (!dragging_ || !window_ || locked_) {
    return;
  }

  POINT cursor{};
  if (!GetCursorPos(&cursor)) {
    return;
  }

  const int width = std::max(
      1,
      static_cast<int>(drag_start_window_rect_.right -
                       drag_start_window_rect_.left));
  const int height = std::max(
      1,
      static_cast<int>(drag_start_window_rect_.bottom -
                       drag_start_window_rect_.top));
  const int screen_width = GetSystemMetrics(SM_CXSCREEN);
  const int screen_height = GetSystemMetrics(SM_CYSCREEN);
  const int max_left = std::max(0, screen_width - width);
  const int max_top = std::max(0, screen_height - height);
  const int left = ClampInt(
      drag_start_window_rect_.left + cursor.x - drag_start_cursor_.x, 0,
      max_left);
  const int top = ClampInt(
      drag_start_window_rect_.top + cursor.y - drag_start_cursor_.y, 0,
      max_top);

  horizontal_position_ =
      max_left > 0 ? static_cast<double>(left) / max_left : 0.5;
  vertical_position_ = max_top > 0 ? static_cast<double>(top) / max_top : 0.0;

  SetWindowPos(window_, HWND_TOPMOST, left, top, width, height,
               SWP_NOACTIVATE | SWP_SHOWWINDOW);
}

void DesktopLyricsWindow::EndDrag() {
  if (!dragging_) {
    return;
  }
  dragging_ = false;
  if (GetCapture() == window_) {
    ReleaseCapture();
  }
  if (position_changed_callback_) {
    position_changed_callback_(horizontal_position_, vertical_position_);
  }
}

void DesktopLyricsWindow::Render() {
  if (!window_ || gdiplus_token_ == 0) {
    return;
  }

  HDC screen_dc = GetDC(nullptr);
  if (!screen_dc) {
    return;
  }

  const int dpi = GetDeviceCaps(screen_dc, LOGPIXELSY);
  const double scale = std::max(1.0, dpi / 96.0);
  const int screen_width = GetSystemMetrics(SM_CXSCREEN);
  const int screen_height = GetSystemMetrics(SM_CYSCREEN);
  const int horizontal_margin = static_cast<int>(48 * scale);
  const int max_width = std::max(240, screen_width - horizontal_margin * 2);
  const float font_px = static_cast<float>(font_size_ * scale);
  const int padding_x = static_cast<int>(18 * scale);
  const int padding_y = static_cast<int>(10 * scale);

  auto font_family = PreferredFontFamily();
  Gdiplus::Font font(font_family.get(), font_px, Gdiplus::FontStyleBold,
                     Gdiplus::UnitPixel);
  Gdiplus::StringFormat format;
  format.SetAlignment(Gdiplus::StringAlignmentCenter);
  format.SetLineAlignment(Gdiplus::StringAlignmentCenter);
  format.SetTrimming(Gdiplus::StringTrimmingEllipsisCharacter);
  format.SetFormatFlags(Gdiplus::StringFormatFlagsLineLimit);

  Gdiplus::Bitmap measure_bitmap(1, 1, PixelFormat32bppPARGB);
  Gdiplus::Graphics measure_graphics(&measure_bitmap);
  const float max_text_height = font_px * 2.7f;
  Gdiplus::RectF measure_rect(0, 0, static_cast<float>(max_width),
                              max_text_height);
  Gdiplus::RectF bounds;
  measure_graphics.MeasureString(text_.c_str(), -1, &font, measure_rect,
                                 &format, &bounds);

  int content_width =
      static_cast<int>(std::ceil(bounds.Width)) + padding_x * 2;
  int content_height =
      static_cast<int>(std::ceil(bounds.Height)) + padding_y * 2;
  content_width = ClampInt(content_width, 180, max_width);
  content_height =
      ClampInt(content_height, static_cast<int>(font_px + padding_y * 2),
               static_cast<int>(font_px * 2.8f + padding_y * 2));
  const bool show_lock_button = hover_controls_ && !locked_;
  const int lock_button_size = static_cast<int>(26 * scale);
  const int control_height =
      show_lock_button ? static_cast<int>(32 * scale) : 0;
  const int width = std::max(content_width, lock_button_size + padding_x * 2);
  const int height = content_height + control_height;
  const int content_left = (width - content_width) / 2;
  const int content_top = control_height;

  BITMAPINFO bitmap_info{};
  bitmap_info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  bitmap_info.bmiHeader.biWidth = width;
  bitmap_info.bmiHeader.biHeight = -height;
  bitmap_info.bmiHeader.biPlanes = 1;
  bitmap_info.bmiHeader.biBitCount = 32;
  bitmap_info.bmiHeader.biCompression = BI_RGB;

  void* bits = nullptr;
  HBITMAP bitmap =
      CreateDIBSection(screen_dc, &bitmap_info, DIB_RGB_COLORS, &bits, nullptr,
                       0);
  if (!bitmap) {
    ReleaseDC(nullptr, screen_dc);
    return;
  }

  HDC memory_dc = CreateCompatibleDC(screen_dc);
  HGDIOBJ old_bitmap = SelectObject(memory_dc, bitmap);

  Gdiplus::Graphics graphics(memory_dc);
  graphics.SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);
  graphics.SetTextRenderingHint(Gdiplus::TextRenderingHintAntiAliasGridFit);
  graphics.Clear(Gdiplus::Color(0, 0, 0, 0));

  Gdiplus::RectF background_rect(
      static_cast<float>(content_left), static_cast<float>(content_top),
      static_cast<float>(content_width), static_cast<float>(content_height));
  Gdiplus::GraphicsPath background_path;
  AddRoundedRectangle(background_path, background_rect,
                      std::min<float>(18.0f * static_cast<float>(scale),
                                      content_height / 2.0f));
  const auto background_alpha = static_cast<BYTE>(
      std::round(ClampDouble(background_opacity_, 0.0, 0.85) * 255.0));
  Gdiplus::SolidBrush background_brush(
      Gdiplus::Color(background_alpha, 0, 0, 0));
  graphics.FillPath(&background_brush, &background_path);

  if (show_lock_button) {
    Gdiplus::SolidBrush hit_bridge(Gdiplus::Color(1, 255, 255, 255));
    graphics.FillRectangle(&hit_bridge, 0.0f, 0.0f,
                           static_cast<float>(width),
                           static_cast<float>(content_top));

    const int button_x = (width - lock_button_size) / 2;
    const int button_y = static_cast<int>(2 * scale);
    lock_button_rect_ = {button_x, button_y, button_x + lock_button_size,
                         button_y + lock_button_size};
    Gdiplus::RectF button_rect(static_cast<float>(button_x),
                               static_cast<float>(button_y),
                               static_cast<float>(lock_button_size),
                               static_cast<float>(lock_button_size));
    Gdiplus::GraphicsPath button_path;
    AddRoundedRectangle(button_path, button_rect, lock_button_size / 2.0f);
    Gdiplus::SolidBrush button_brush(Gdiplus::Color(232, 255, 255, 255));
    Gdiplus::Pen button_border(Gdiplus::Color(185, 74, 166, 106),
                               std::max(1.0f, static_cast<float>(scale)));
    graphics.FillPath(&button_brush, &button_path);
    graphics.DrawPath(&button_border, &button_path);
    DrawLockIcon(graphics, button_rect, Gdiplus::Color(255, 31, 42, 36),
                 static_cast<float>(scale));
  } else {
    SetRectEmpty(&lock_button_rect_);
  }

  Gdiplus::RectF text_rect(
      static_cast<float>(content_left + padding_x),
      static_cast<float>(content_top + padding_y),
      static_cast<float>(content_width - padding_x * 2),
      static_cast<float>(content_height - padding_y * 2));
  Gdiplus::RectF shadow_rect = text_rect;
  shadow_rect.Offset(0, static_cast<float>(1.5 * scale));
  Gdiplus::SolidBrush shadow_brush(Gdiplus::Color(120, 0, 0, 0));
  graphics.DrawString(text_.c_str(), -1, &font, shadow_rect, &format,
                      &shadow_brush);

  BYTE alpha = static_cast<BYTE>((color_value_ >> 24) & 0xFF);
  if (alpha == 0) {
    alpha = 0xFF;
  }
  const BYTE red = static_cast<BYTE>((color_value_ >> 16) & 0xFF);
  const BYTE green = static_cast<BYTE>((color_value_ >> 8) & 0xFF);
  const BYTE blue = static_cast<BYTE>(color_value_ & 0xFF);
  Gdiplus::SolidBrush text_brush(Gdiplus::Color(alpha, red, green, blue));
  graphics.DrawString(text_.c_str(), -1, &font, text_rect, &format,
                      &text_brush);

  const int content_screen_left = ClampInt(
      static_cast<int>(
          std::round((screen_width - content_width) * horizontal_position_)),
      0, std::max(0, screen_width - content_width));
  const int content_screen_top = ClampInt(
      static_cast<int>(std::round((screen_height - content_height) *
                                  vertical_position_)),
      0, std::max(0, screen_height - content_height));
  const int left = ClampInt(content_screen_left - content_left, 0,
                            std::max(0, screen_width - width));
  const int top = ClampInt(content_screen_top - content_top, 0,
                           std::max(0, screen_height - height));
  POINT destination{left, top};
  SIZE size{width, height};
  POINT source{0, 0};
  BLENDFUNCTION blend{};
  blend.BlendOp = AC_SRC_OVER;
  blend.SourceConstantAlpha = 255;
  blend.AlphaFormat = AC_SRC_ALPHA;

  UpdateLayeredWindow(window_, screen_dc, &destination, &size, memory_dc,
                      &source, 0, &blend, ULW_ALPHA);
  SetWindowPos(window_, HWND_TOPMOST, left, top, width, height,
               SWP_NOACTIVATE | SWP_SHOWWINDOW);

  SelectObject(memory_dc, old_bitmap);
  DeleteDC(memory_dc);
  DeleteObject(bitmap);
  ReleaseDC(nullptr, screen_dc);
}

ATOM DesktopLyricsWindow::RegisterWindowClass() {
  static ATOM atom = 0;
  if (atom != 0) {
    return atom;
  }

  WNDCLASSW window_class{};
  window_class.lpfnWndProc = DesktopLyricsWindow::WindowProc;
  window_class.hInstance = GetModuleHandle(nullptr);
  window_class.lpszClassName = kDesktopLyricsWindowClass;
  window_class.hCursor = LoadCursor(nullptr, IDC_ARROW);
  atom = RegisterClassW(&window_class);
  return atom;
}

LRESULT CALLBACK DesktopLyricsWindow::WindowProc(HWND hwnd,
                                                 UINT message,
                                                 WPARAM wparam,
                                                 LPARAM lparam) {
  DesktopLyricsWindow* window = nullptr;
  if (message == WM_NCCREATE) {
    const auto create_struct = reinterpret_cast<CREATESTRUCTW*>(lparam);
    window = reinterpret_cast<DesktopLyricsWindow*>(
        create_struct->lpCreateParams);
    SetWindowLongPtrW(
        hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(window));
  } else {
    window = reinterpret_cast<DesktopLyricsWindow*>(
        GetWindowLongPtrW(hwnd, GWLP_USERDATA));
  }

  switch (message) {
    case WM_NCHITTEST:
      return window && window->locked_ ? HTTRANSPARENT : HTCLIENT;
    case WM_LBUTTONDOWN:
      if (window && !window->locked_) {
        POINT point{GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
        if (window->IsPointInLockButton(point)) {
          window->lock_button_pressed_ = true;
          SetCapture(hwnd);
          return 0;
        }
        window->BeginDrag();
        return 0;
      }
      break;
    case WM_MOUSEMOVE:
      if (window && !window->locked_) {
        KillTimer(hwnd, kHideControlsTimerId);
        window->StartMouseLeaveTracking();
        if (window->dragging_) {
          window->ContinueDrag();
          return 0;
        }
        if (!window->hover_controls_) {
          window->hover_controls_ = true;
          window->Render();
        }
        return 0;
      }
      break;
    case WM_MOUSELEAVE:
      if (window) {
        window->tracking_mouse_leave_ = false;
        if (!window->dragging_ && !window->locked_ &&
            window->hover_controls_) {
          SetTimer(hwnd, kHideControlsTimerId, kHideControlsDelayMs, nullptr);
        }
        return 0;
      }
      break;
    case WM_TIMER:
      if (wparam == kHideControlsTimerId && window) {
        KillTimer(hwnd, kHideControlsTimerId);
        if (!window->dragging_ && !window->locked_ &&
            window->hover_controls_) {
          POINT cursor{};
          RECT window_rect{};
          GetCursorPos(&cursor);
          GetWindowRect(hwnd, &window_rect);
          if (PtInRect(&window_rect, cursor)) {
            window->StartMouseLeaveTracking();
            return 0;
          }
          window->hover_controls_ = false;
          window->lock_button_pressed_ = false;
          window->Render();
        }
        return 0;
      }
      break;
    case WM_LBUTTONUP:
      if (window) {
        POINT point{GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
        if (window->lock_button_pressed_) {
          window->lock_button_pressed_ = false;
          if (GetCapture() == hwnd) {
            ReleaseCapture();
          }
          if (window->IsPointInLockButton(point)) {
            window->LockFromButton();
          }
          return 0;
        }
        window->EndDrag();
        return 0;
      }
      break;
    case WM_CAPTURECHANGED:
      if (window && reinterpret_cast<HWND>(lparam) != hwnd) {
        window->lock_button_pressed_ = false;
        window->EndDrag();
        return 0;
      }
      break;
    case WM_NCDESTROY:
      SetWindowLongPtrW(hwnd, GWLP_USERDATA, 0);
      break;
  }
  return DefWindowProcW(hwnd, message, wparam, lparam);
}
