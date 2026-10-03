#include "desktop_integration.h"
#include "audio_route_monitor.h"
#include "channel_utils.h"
#include "cloud_login.h"
#include "media_controls.h"
#include <libayatana-appindicator/app-indicator.h>
#include <algorithm>
#include <memory>

namespace {
gchar* preferences_path() {
  return g_build_filename(g_get_user_config_dir(), "qingting", "desktop.ini", nullptr);
}
GKeyFile* load_preferences() {
  auto* preferences = g_key_file_new();
  g_autofree gchar* path = preferences_path();
  g_key_file_load_from_file(preferences, path, G_KEY_FILE_NONE, nullptr);
  return preferences;
}
}  // namespace

void restore_desktop_window(GtkWindow* window) {
  g_autoptr(GKeyFile) prefs = load_preferences();
  int width = g_key_file_get_integer(prefs, "window", "width", nullptr);
  int height = g_key_file_get_integer(prefs, "window", "height", nullptr);
  if (width < 480) width = 1280;
  if (height < 320) height = 720;
  GdkDisplay* display = gtk_widget_get_display(GTK_WIDGET(window));
  GdkMonitor* monitor = gdk_display_get_primary_monitor(display);
  if (monitor == nullptr && gdk_display_get_n_monitors(display) > 0)
    monitor = gdk_display_get_monitor(display, 0);
  if (monitor != nullptr) {
    GdkRectangle area; gdk_monitor_get_workarea(monitor, &area);
    width = std::min(width, std::max(480, area.width - 40));
    height = std::min(height, std::max(320, area.height - 40));
  }
  gtk_window_set_default_size(window, width, height);
  g_object_set_data(G_OBJECT(window), "qingting-normal-width", GINT_TO_POINTER(width));
  g_object_set_data(G_OBJECT(window), "qingting-normal-height", GINT_TO_POINTER(height));
  if (g_key_file_get_boolean(prefs, "window", "maximized", nullptr)) gtk_window_maximize(window);
}

namespace {

struct DesktopIntegration {
  FlMethodChannel* desktop_channel = nullptr;
  FlMethodChannel* lifecycle_channel = nullptr;
  FlMethodChannel* file_channel = nullptr;
  std::unique_ptr<CloudLogin> login;
  std::unique_ptr<MediaControls> media;
  std::unique_ptr<AudioRouteMonitor> audio;
  GtkWindow* window = nullptr;
  AppIndicator* indicator = nullptr;
  GtkWidget* menu = nullptr;
  guint save_timer = 0;
  bool tray_connected = false;
  bool close_to_tray = true;
  GtkFileChooserNative* picker = nullptr;
  FlMethodCall* picker_call = nullptr;
  bool closing = false;

  ~DesktopIntegration() {
    if (save_timer != 0) g_source_remove(save_timer);
    login.reset(); audio.reset(); media.reset();
    if (indicator != nullptr) {
      app_indicator_set_status(indicator, APP_INDICATOR_STATUS_PASSIVE);
      g_signal_handlers_disconnect_by_data(indicator, window);
    }
    g_clear_object(&indicator);
    if (menu != nullptr) { gtk_widget_destroy(menu); g_object_unref(menu); }
    if (picker != nullptr) {
      gtk_native_dialog_destroy(GTK_NATIVE_DIALOG(picker));
    }
    g_clear_object(&picker);
    g_clear_object(&picker_call);
    g_clear_object(&desktop_channel);
    g_clear_object(&lifecycle_channel);
    g_clear_object(&file_channel);
  }
};

DesktopIntegration* integration(GtkWindow* window) {
  return static_cast<DesktopIntegration*>(
      g_object_get_data(G_OBJECT(window), "qingting-desktop"));
}

const gchar* string_argument(FlMethodCall* call, const gchar* key) {
  FlValue* args = fl_method_call_get_args(call);
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
    return nullptr;
  }
  FlValue* value = fl_value_lookup_string(args, key);
  return value != nullptr && fl_value_get_type(value) == FL_VALUE_TYPE_STRING
             ? fl_value_get_string(value)
             : nullptr;
}

void present(GtkWindow* window) {
  gtk_widget_show(GTK_WIDGET(window));
  gtk_window_deiconify(window);
  gtk_window_present(window);
}

void save_preferences(GtkWindow* window) {
  auto* state = integration(window);
  g_autoptr(GKeyFile) prefs = load_preferences();
  g_key_file_set_integer(prefs, "window", "width", GPOINTER_TO_INT(g_object_get_data(G_OBJECT(window), "qingting-normal-width")));
  g_key_file_set_integer(prefs, "window", "height", GPOINTER_TO_INT(g_object_get_data(G_OBJECT(window), "qingting-normal-height")));
  g_key_file_set_boolean(prefs, "window", "maximized", gtk_window_is_maximized(window));
  g_key_file_set_boolean(prefs, "desktop", "closeToTray", state->close_to_tray);
  g_autofree gchar* path = preferences_path();
  g_autofree gchar* directory = g_path_get_dirname(path);
  g_mkdir_with_parents(directory, 0700);
  g_autoptr(GError) error = nullptr;
  if (!g_key_file_save_to_file(prefs, path, &error)) g_warning("Window preferences could not be saved: %s", error->message);
}

void schedule_save(GtkWindow* window) {
  auto* state = integration(window);
  if (state->save_timer != 0) g_source_remove(state->save_timer);
  state->save_timer = g_timeout_add(350, +[](gpointer data) -> gboolean {
    auto* window = GTK_WINDOW(data);
    integration(window)->save_timer = 0;
    save_preferences(window);
    return G_SOURCE_REMOVE;
  }, window);
}

void request_exit(GtkWindow* window);

struct RevealRequest {
  GtkWindow* window;
  FlMethodCall* call;
  gchar* uri;
};

void reveal_complete(GObject* source, GAsyncResult* result, gpointer data) {
  auto* request = static_cast<RevealRequest*>(data);
  g_autoptr(GError) error = nullptr;
  g_autoptr(GVariant) response = g_dbus_connection_call_finish(G_DBUS_CONNECTION(source), result, &error);
  bool success = response != nullptr;
  if (!success) {
    g_clear_error(&error);
    g_autoptr(GFile) file = g_file_new_for_uri(request->uri);
    g_autoptr(GFile) parent = g_file_get_parent(file);
    g_autofree gchar* uri = parent != nullptr ? g_file_get_uri(parent) : nullptr;
    success = uri != nullptr && gtk_show_uri_on_window(request->window, uri, GDK_CURRENT_TIME, &error);
  }
  if (success) {
    g_autoptr(FlValue) value = fl_value_new_bool(TRUE);
    fl_method_call_respond_success(request->call, value, nullptr);
  } else fl_method_call_respond_error(request->call, "open_failed", "无法打开歌曲所在目录", nullptr, nullptr);
  g_object_unref(request->call); g_object_unref(request->window); g_free(request->uri); delete request;
}

void trash_complete(GObject* source, GAsyncResult* result, gpointer data) {
  g_autoptr(FlMethodCall) call = FL_METHOD_CALL(data);
  g_autoptr(GError) error = nullptr;
  if (g_file_trash_finish(G_FILE(source), result, &error)) {
    g_autoptr(FlValue) value = fl_value_new_bool(TRUE);
    fl_method_call_respond_success(call, value, nullptr);
  } else {
    fl_method_call_respond_error(call, "trash_failed", "无法移入回收站，歌曲文件已保留", nullptr, nullptr);
  }
}

void file_method_call(FlMethodChannel*, FlMethodCall* call, gpointer) {
  if (!g_str_equal(fl_method_call_get_name(call), "moveToRecycleBin")) {
    fl_method_call_respond_not_implemented(call, nullptr); return;
  }
  const char* path = string_argument(call, "path");
  if (path == nullptr || !g_path_is_absolute(path)) {
    fl_method_call_respond_error(call, "invalid_path", "需要绝对文件路径", nullptr, nullptr); return;
  }
  g_autoptr(GFile) file = g_file_new_for_path(path);
  g_file_trash_async(file, G_PRIORITY_DEFAULT, nullptr, trash_complete, g_object_ref(call));
}

void picker_response(GtkNativeDialog* dialog, gint response,
                     gpointer user_data) {
  auto* state = static_cast<DesktopIntegration*>(user_data);
  g_autofree gchar* path =
      response == GTK_RESPONSE_ACCEPT
          ? gtk_file_chooser_get_filename(GTK_FILE_CHOOSER(dialog))
          : nullptr;
  g_autoptr(FlValue) value =
      path != nullptr ? fl_value_new_string(path) : fl_value_new_null();
  fl_method_call_respond_success(state->picker_call, value, nullptr);
  g_clear_object(&state->picker_call);
  gtk_native_dialog_destroy(dialog);
  g_clear_object(&state->picker);
}

void desktop_method_call(FlMethodChannel* channel, FlMethodCall* call,
                         gpointer user_data) {
  auto* window = GTK_WINDOW(user_data);
  auto* state = integration(window);
  const gchar* method = fl_method_call_get_name(call);
  if (g_str_equal(method, "login")) { state->login->Start(call); return; }
  if (g_str_equal(method, "cancelLogin")) {
    state->login->Cancel();
    fl_method_call_respond_success(call, nullptr, nullptr); return;
  }
  if (g_str_equal(method, "getSettings")) {
    g_autoptr(FlValue) value = fl_value_new_map();
    fl_value_set_string_take(value, "closeToTray", fl_value_new_bool(state->close_to_tray));
    fl_value_set_string_take(value, "trayAvailable", fl_value_new_bool(state->tray_connected));
    fl_method_call_respond_success(call, value, nullptr); return;
  }
  if (g_str_equal(method, "setCloseToTray")) {
    state->close_to_tray = channel_bool(fl_method_call_get_args(call), "enabled");
    save_preferences(window);
    fl_method_call_respond_success(call, nullptr, nullptr); return;
  }
  if (g_str_equal(method, "quit")) {
    fl_method_call_respond_success(call, nullptr, nullptr);
    request_exit(window); return;
  }
  if (g_str_equal(method, "revealFile")) {
    const char* uri = string_argument(call, "uri");
    if (uri == nullptr || !g_str_has_prefix(uri, "file://")) {
      fl_method_call_respond_error(call, "invalid_uri", "需要本地文件地址", nullptr, nullptr); return;
    }
    g_autoptr(GDBusConnection) bus = g_bus_get_sync(G_BUS_TYPE_SESSION, nullptr, nullptr);
    if (bus == nullptr) {
      fl_method_call_respond_error(call, "no_bus", "无法连接桌面文件管理器", nullptr, nullptr); return;
    }
    const char* uris[] = {uri, nullptr};
    auto* request = new RevealRequest{GTK_WINDOW(g_object_ref(window)), FL_METHOD_CALL(g_object_ref(call)), g_strdup(uri)};
    g_dbus_connection_call(bus, "org.freedesktop.FileManager1", "/org/freedesktop/FileManager1",
        "org.freedesktop.FileManager1", "ShowItems", g_variant_new("(^ass)", uris, ""),
        nullptr, G_DBUS_CALL_FLAGS_NONE, 1500, nullptr, reveal_complete, request);
    return;
  }
  if (g_str_equal(method, "pickDirectory")) {
    if (state->picker != nullptr || state->closing) {
      fl_method_call_respond_error(call, "busy", "A dialog is already open.",
                                   nullptr, nullptr);
      return;
    }
    state->picker = gtk_file_chooser_native_new(
        "选择青听下载目录", window, GTK_FILE_CHOOSER_ACTION_SELECT_FOLDER,
        "选择", "取消");
    gtk_native_dialog_set_modal(GTK_NATIVE_DIALOG(state->picker), TRUE);
    gtk_file_chooser_set_local_only(GTK_FILE_CHOOSER(state->picker), TRUE);
    gtk_file_chooser_set_create_folders(GTK_FILE_CHOOSER(state->picker), TRUE);
    const gchar* initial = string_argument(call, "initialDirectory");
    if (initial != nullptr && g_file_test(initial, G_FILE_TEST_IS_DIR)) {
      gtk_file_chooser_set_current_folder(GTK_FILE_CHOOSER(state->picker),
                                          initial);
    }
    state->picker_call = FL_METHOD_CALL(g_object_ref(call));
    g_signal_connect(state->picker, "response", G_CALLBACK(picker_response),
                     state);
    gtk_native_dialog_show(GTK_NATIVE_DIALOG(state->picker));
    return;
  }
  if (g_str_equal(method, "openUri")) {
    const gchar* uri = string_argument(call, "uri");
    g_autofree gchar* scheme =
        uri != nullptr ? g_uri_parse_scheme(uri) : nullptr;
    if (scheme == nullptr ||
        !(g_str_equal(scheme, "http") || g_str_equal(scheme, "https") ||
          g_str_equal(scheme, "file"))) {
      fl_method_call_respond_error(call, "invalid_uri", "Unsupported URI.",
                                   nullptr, nullptr);
      return;
    }
    g_autoptr(GError) error = nullptr;
    if (!gtk_show_uri_on_window(window, uri, GDK_CURRENT_TIME, &error)) {
      fl_method_call_respond_error(call, "open_failed", error->message, nullptr,
                                   nullptr);
      return;
    }
    g_autoptr(FlValue) value = fl_value_new_bool(TRUE);
    fl_method_call_respond_success(call, value, nullptr);
    return;
  }
  fl_method_call_respond_not_implemented(call, nullptr);
}

void prepared_to_exit(GObject* source, GAsyncResult* result,
                      gpointer user_data) {
  g_autoptr(GtkWindow) window = GTK_WINDOW(user_data);
  auto* state = integration(window);
  g_autoptr(GError) error = nullptr;
  g_autoptr(FlMethodResponse) response = fl_method_channel_invoke_method_finish(
      FL_METHOD_CHANNEL(source), result, &error);
  // An unregistered Dart handler is possible if the window closes during
  // startup.
  if (response != nullptr &&
      (FL_IS_METHOD_SUCCESS_RESPONSE(response) ||
       FL_IS_METHOD_NOT_IMPLEMENTED_RESPONSE(response))) {
    // End the application loop before disposing Flutter's implicit view.
    // Destroying it inside this callback can race queued compositor frames.
    g_application_quit(G_APPLICATION(gtk_window_get_application(window)));
    return;
  }
  state->closing = false;
  gtk_widget_set_sensitive(GTK_WIDGET(window), TRUE);
  g_warning("Could not finish saving before exit: %s",
            error != nullptr ? error->message : "Dart save request failed");
  GtkWidget* dialog = gtk_message_dialog_new(
      window, GTK_DIALOG_MODAL, GTK_MESSAGE_ERROR, GTK_BUTTONS_CLOSE, "%s",
      "退出前保存未完成，请稍后重试关闭窗口。");
  g_signal_connect_swapped(dialog, "response", G_CALLBACK(gtk_widget_destroy),
                           dialog);
  gtk_widget_show(dialog);
}

void request_exit(GtkWindow* window) {
  GtkWidget* widget = GTK_WIDGET(window);
  auto* state = integration(window);
  if (!state->closing) {
    state->closing = true;
    save_preferences(window);
    state->login->Cancel();
    if (state->picker != nullptr) {
      picker_response(GTK_NATIVE_DIALOG(state->picker), GTK_RESPONSE_CANCEL,
                      state);
    }
    // Stop new UI changes until the pending settings and queue writes settle.
    gtk_widget_set_sensitive(widget, FALSE);
    fl_method_channel_invoke_method(state->lifecycle_channel, "prepareToExit",
                                    nullptr, nullptr, prepared_to_exit,
                                    g_object_ref(window));
  }
}

gboolean delete_event(GtkWidget* widget, GdkEvent*, gpointer) {
  auto* window = GTK_WINDOW(widget);
  auto* state = integration(window);
  if (!state->closing && state->close_to_tray && state->tray_connected) {
    save_preferences(window);
    gtk_widget_hide(widget);
  } else request_exit(window);
  return TRUE;
}

}  // namespace

void register_desktop_integration(FlView* view, GtkWindow* window) {
  auto* state = new DesktopIntegration();
  state->window = window;
  g_autoptr(GKeyFile) prefs = load_preferences();
  if (g_key_file_has_key(prefs, "desktop", "closeToTray", nullptr))
    state->close_to_tray = g_key_file_get_boolean(prefs, "desktop", "closeToTray", nullptr);
  g_object_set_data_full(
      G_OBJECT(window), "qingting-desktop", state,
      [](gpointer data) { delete static_cast<DesktopIntegration*>(data); });
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  FlBinaryMessenger* messenger =
      fl_engine_get_binary_messenger(fl_view_get_engine(view));
  state->desktop_channel = fl_method_channel_new(
      messenger, "qingting/linux_desktop", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(
      state->desktop_channel, desktop_method_call, window, nullptr);
  state->lifecycle_channel = fl_method_channel_new(
      messenger, "qingting/app_lifecycle", FL_METHOD_CODEC(codec));
  state->file_channel = fl_method_channel_new(messenger, "qingting/file_operations", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(state->file_channel, file_method_call, window, nullptr);
  state->login = std::make_unique<CloudLogin>(window);
  state->media = std::make_unique<MediaControls>(messenger,
      [window]() { present(window); }, [window]() { request_exit(window); });
  state->audio = std::make_unique<AudioRouteMonitor>(messenger);
  state->menu = gtk_menu_new();
  g_object_ref_sink(state->menu);
  const char* labels[] = {"打开青听", "播放 / 暂停", "上一首", "下一首", "退出青听"};
  for (int i = 0; i < 5; ++i) {
    auto* item = gtk_menu_item_new_with_label(labels[i]);
    g_object_set_data(G_OBJECT(item), "qingting-action", GINT_TO_POINTER(i));
    g_signal_connect(item, "activate", G_CALLBACK(+[](GtkMenuItem* item, gpointer data) {
      auto* window = GTK_WINDOW(data);
      auto* state = integration(window);
      int action = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(item), "qingting-action"));
      if (action == 0) present(window);
      else if (action == 4) request_exit(window);
      else if (!state->closing) state->media->Action(action == 1 ? "toggle" : action == 2 ? "previous" : "next");
    }), window);
    gtk_menu_shell_append(GTK_MENU_SHELL(state->menu), item);
  }
  gtk_widget_show_all(state->menu);
  // The helper constructor is deprecated in newer Ayatana releases. These
  // GObject properties also work with the GTK 3 library on Ubuntu 24.04.
  state->indicator = APP_INDICATOR(g_object_new(
      APP_INDICATOR_TYPE, "id", "qingting", "icon-name", "com.pobb.qingting",
      "category", "ApplicationStatus", nullptr));
  g_autofree gchar* executable = g_file_read_link("/proc/self/exe", nullptr);
  g_autofree gchar* directory = executable == nullptr ? nullptr : g_path_get_dirname(executable);
  g_autofree gchar* icon = directory == nullptr ? nullptr : g_build_filename(directory, "data", "flutter_assets", "assets", "logo.jpg", nullptr);
  if (icon != nullptr && g_file_test(icon, G_FILE_TEST_IS_REGULAR)) app_indicator_set_icon_full(state->indicator, icon, "青听");
  app_indicator_set_title(state->indicator, "青听");
  app_indicator_set_menu(state->indicator, GTK_MENU(state->menu));
  app_indicator_set_status(state->indicator, APP_INDICATOR_STATUS_ACTIVE);
  gboolean connected = FALSE;
  g_object_get(state->indicator, "connected", &connected, nullptr);
  state->tray_connected = connected;
  g_signal_connect(state->indicator, "connection-changed", G_CALLBACK(+[](AppIndicator*, gboolean connected, gpointer data) {
    auto* window = GTK_WINDOW(data);
    integration(window)->tray_connected = connected;
    if (!connected && !integration(window)->closing && !gtk_widget_get_visible(GTK_WIDGET(window))) present(window);
  }), window);
  g_signal_connect(window, "configure-event", G_CALLBACK(+[](GtkWidget* widget, GdkEventConfigure* event, gpointer) -> gboolean {
    auto* window = GTK_WINDOW(widget);
    GdkWindow* native = gtk_widget_get_window(widget);
    GdkWindowState flags = native == nullptr ? static_cast<GdkWindowState>(0) : gdk_window_get_state(native);
    if (!(flags & (GDK_WINDOW_STATE_MAXIMIZED | GDK_WINDOW_STATE_FULLSCREEN | GDK_WINDOW_STATE_ICONIFIED)) &&
        event->width >= 480 && event->height >= 320) {
      g_object_set_data(G_OBJECT(window), "qingting-normal-width", GINT_TO_POINTER(event->width));
      g_object_set_data(G_OBJECT(window), "qingting-normal-height", GINT_TO_POINTER(event->height));
    }
    schedule_save(window); return FALSE;
  }), nullptr);
  g_signal_connect(window, "window-state-event", G_CALLBACK(+[](GtkWidget* widget, GdkEventWindowState*, gpointer) -> gboolean {
    schedule_save(GTK_WINDOW(widget)); return FALSE;
  }), nullptr);
  g_signal_connect(window, "delete-event", G_CALLBACK(delete_event), nullptr);
}
