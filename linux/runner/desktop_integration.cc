#include "desktop_integration.h"

namespace {

struct DesktopIntegration {
  FlMethodChannel* desktop_channel = nullptr;
  FlMethodChannel* lifecycle_channel = nullptr;
  GtkFileChooserNative* picker = nullptr;
  FlMethodCall* picker_call = nullptr;
  bool closing = false;

  ~DesktopIntegration() {
    if (picker != nullptr) {
      gtk_native_dialog_destroy(GTK_NATIVE_DIALOG(picker));
    }
    g_clear_object(&picker);
    g_clear_object(&picker_call);
    g_clear_object(&desktop_channel);
    g_clear_object(&lifecycle_channel);
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
    gtk_widget_destroy(GTK_WIDGET(window));
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

gboolean delete_event(GtkWidget* widget, GdkEvent* event, gpointer user_data) {
  auto* window = GTK_WINDOW(widget);
  auto* state = integration(window);
  if (!state->closing) {
    state->closing = true;
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
  return TRUE;
}

}  // namespace

void register_desktop_integration(FlView* view, GtkWindow* window) {
  auto* state = new DesktopIntegration();
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
  g_signal_connect(window, "delete-event", G_CALLBACK(delete_event), nullptr);
}
