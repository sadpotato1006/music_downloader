#ifndef QINGTING_DESKTOP_INTEGRATION_H_
#define QINGTING_DESKTOP_INTEGRATION_H_

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

void register_desktop_integration(FlView* view, GtkWindow* window);

#endif  // QINGTING_DESKTOP_INTEGRATION_H_
