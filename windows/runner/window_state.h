#ifndef RUNNER_WINDOW_STATE_H_
#define RUNNER_WINDOW_STATE_H_

#include <windows.h>

namespace window_state {

struct WindowSize {
  unsigned int width;
  unsigned int height;
};

WindowSize LoadWindowSize(unsigned int default_width,
                          unsigned int default_height);
void SaveWindowSize(HWND window);

}  // namespace window_state

#endif  // RUNNER_WINDOW_STATE_H_