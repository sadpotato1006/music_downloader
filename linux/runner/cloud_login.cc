#include "cloud_login.h"
#include "channel_utils.h"

CloudLogin::~CloudLogin() {
  Cancel();
  g_free(callback_);
  g_free(promoted_qr_uri_);
}

bool CloudLogin::MatchesCallback(const char* uri, const char* callback) {
  g_autoptr(GUri) actual = g_uri_parse(uri, G_URI_FLAGS_NONE, nullptr);
  g_autoptr(GUri) expected = g_uri_parse(callback, G_URI_FLAGS_NONE, nullptr);
  return actual != nullptr && expected != nullptr &&
         g_strcmp0(g_uri_get_scheme(actual), g_uri_get_scheme(expected)) == 0 &&
         g_strcmp0(g_uri_get_host(actual), g_uri_get_host(expected)) == 0 &&
         g_uri_get_port(actual) == g_uri_get_port(expected) &&
         g_strcmp0(g_uri_get_path(actual), g_uri_get_path(expected)) == 0 &&
         g_uri_get_userinfo(actual) == nullptr &&
         g_uri_get_fragment(actual) == nullptr;
}

bool CloudLogin::IsSchoolQrPage(const char* uri) {
  if (uri == nullptr) return false;
  g_autoptr(GUri) page = g_uri_parse(uri, G_URI_FLAGS_ENCODED_QUERY, nullptr);
  if (page == nullptr || g_strcmp0(g_uri_get_scheme(page), "https") != 0 ||
      g_strcmp0(g_uri_get_host(page), "sis.ustb.edu.cn") != 0 ||
      (g_uri_get_port(page) != -1 && g_uri_get_port(page) != 443) ||
      g_strcmp0(g_uri_get_path(page), "/connect/qrpage") != 0 ||
      g_uri_get_userinfo(page) != nullptr || g_uri_get_fragment(page) != nullptr ||
      g_uri_get_query(page) == nullptr) return false;
  g_autoptr(GHashTable) params = g_uri_parse_params(
      g_uri_get_query(page), -1, "&", G_URI_PARAMS_NONE, nullptr);
  const char* return_url = params == nullptr ? nullptr :
      static_cast<const char*>(g_hash_table_lookup(params, "return_url"));
  if (return_url == nullptr) return false;
  g_autoptr(GUri) target = g_uri_parse(return_url, G_URI_FLAGS_NONE, nullptr);
  return target != nullptr && g_strcmp0(g_uri_get_scheme(target), "https") == 0 &&
         g_strcmp0(g_uri_get_host(target), "sso.ustb.edu.cn") == 0 &&
         (g_uri_get_port(target) == -1 || g_uri_get_port(target) == 443) &&
         g_strcmp0(g_uri_get_path(target),
                   "/idp/authCenter/authenticateByLck") == 0 &&
         g_uri_get_userinfo(target) == nullptr &&
         g_uri_get_fragment(target) == nullptr;
}

void CloudLogin::Start(FlMethodCall* call) {
  if (call_ != nullptr || window_ != nullptr) {
    if (window_ != nullptr) gtk_window_present(GTK_WINDOW(window_));
    fl_method_call_respond_error(call, "busy", "扫码登录窗口已打开", nullptr, nullptr);
    return;
  }
  FlValue* args = fl_method_call_get_args(call);
  const char* url = channel_string(args, "url");
  const char* callback = channel_string(args, "callbackUrl");
  g_autoptr(GUri) initial = g_uri_parse(url, G_URI_FLAGS_NONE, nullptr);
  // OAuth uses an intercepted HTTPS callback; never disable TLS validation.
  if (initial == nullptr || g_strcmp0(g_uri_get_scheme(initial), "https") != 0 ||
      g_uri_get_host(initial) == nullptr ||
      !g_str_equal(callback, "https://127.0.0.1:9010/callback")) {
    fl_method_call_respond_error(call, "invalid_url", "无效的云盘登录地址", nullptr, nullptr);
    return;
  }
  callback_ = g_strdup(callback);
  call_ = FL_METHOD_CALL(g_object_ref(call));
  window_ = gtk_window_new(GTK_WINDOW_TOPLEVEL);
  gtk_window_set_title(GTK_WINDOW(window_), "青听 · 北科云盘扫码登录");
  gtk_window_set_default_size(GTK_WINDOW(window_), 960, 720);
  gtk_window_set_transient_for(GTK_WINDOW(window_), parent_);
  gtk_window_set_modal(GTK_WINDOW(window_), TRUE);
  gtk_window_set_destroy_with_parent(GTK_WINDOW(window_), TRUE);
  auto* box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
  auto* label = gtk_label_new("点击个人用户登录，用微信扫码后在手机上确认登录。关闭此窗口可取消。");
  gtk_widget_set_margin_top(label, 12);
  gtk_widget_set_margin_bottom(label, 8);
  gtk_box_pack_start(GTK_BOX(box), label, FALSE, FALSE, 0);
  g_autoptr(WebKitWebContext) context = webkit_web_context_new_ephemeral();
  web_view_ = WEBKIT_WEB_VIEW(g_object_new(WEBKIT_TYPE_WEB_VIEW,
      "web-context", context, "is-ephemeral", TRUE, nullptr));
  gtk_box_pack_start(GTK_BOX(box), GTK_WIDGET(web_view_), TRUE, TRUE, 0);
  gtk_container_add(GTK_CONTAINER(window_), box);
  g_signal_connect(window_, "destroy", G_CALLBACK(Destroyed), this);
  ConnectWebViewSignals();
  gtk_widget_show_all(window_);
  webkit_web_view_load_uri(web_view_, url);
}

void CloudLogin::ConnectWebViewSignals() {
  g_signal_connect(web_view_, "decide-policy", G_CALLBACK(Decide), this);
  g_signal_connect(web_view_, "load-failed", G_CALLBACK(LoadFailed), this);
  g_signal_connect(web_view_, "web-process-terminated",
      G_CALLBACK(+[](WebKitWebView*, WebKitWebProcessTerminationReason, gpointer data) {
        static_cast<CloudLogin*>(data)->Complete(nullptr, "登录页面进程已退出，请重试");
      }), this);
}

void CloudLogin::LoadInMainFrame(const char* uri) {
  g_free(pending_uri_);
  pending_uri_ = g_strdup(uri);
  if (navigate_idle_ != 0) return;
  // Finish the iframe policy decision before replacing the top-level document.
  navigate_idle_ = g_idle_add(+[](gpointer data) -> gboolean {
    auto* self = static_cast<CloudLogin*>(data);
    self->navigate_idle_ = 0;
    g_autofree gchar* uri = self->pending_uri_;
    self->pending_uri_ = nullptr;
    if (self->web_view_ != nullptr) webkit_web_view_load_uri(self->web_view_, uri);
    return G_SOURCE_REMOVE;
  }, this);
}

void CloudLogin::StopPendingNavigation() {
  if (navigate_idle_ != 0) { g_source_remove(navigate_idle_); navigate_idle_ = 0; }
  g_clear_pointer(&pending_uri_, g_free);
}

void CloudLogin::Complete(const char* uri, const char* error) {
  if (call_ == nullptr) return;
  StopPendingNavigation();
  if (error != nullptr) {
    fl_method_call_respond_error(call_, "login_failed", error, nullptr, nullptr);
  } else {
    g_autoptr(FlValue) result = uri != nullptr ? fl_value_new_string(uri) : fl_value_new_null();
    fl_method_call_respond_success(call_, result, nullptr);
  }
  g_clear_object(&call_);
  // Let WebKit finish handling the policy decision before destroying its view.
  if (window_ != nullptr && close_idle_ == 0) {
    close_idle_ = g_idle_add(+[](gpointer data) -> gboolean {
      auto* self = static_cast<CloudLogin*>(data);
      self->close_idle_ = 0;
      if (self->window_ != nullptr) gtk_widget_destroy(self->window_);
      return G_SOURCE_REMOVE;
    }, this);
  }
}

void CloudLogin::Cancel() {
  StopPendingNavigation();
  if (close_idle_ != 0) { g_source_remove(close_idle_); close_idle_ = 0; }
  if (window_ != nullptr) gtk_widget_destroy(window_);
  else if (call_ != nullptr) Complete(nullptr);
}

void CloudLogin::Destroyed(GtkWidget*, gpointer data) {
  auto* self = static_cast<CloudLogin*>(data);
  self->window_ = nullptr;
  self->web_view_ = nullptr;
  self->StopPendingNavigation();
  if (self->close_idle_ != 0) { g_source_remove(self->close_idle_); self->close_idle_ = 0; }
  self->Complete(nullptr);
  g_clear_pointer(&self->callback_, g_free);
  g_clear_pointer(&self->promoted_qr_uri_, g_free);
}

gboolean CloudLogin::Decide(WebKitWebView*, WebKitPolicyDecision* decision,
                            WebKitPolicyDecisionType type, gpointer data) {
  if (type != WEBKIT_POLICY_DECISION_TYPE_NAVIGATION_ACTION &&
      type != WEBKIT_POLICY_DECISION_TYPE_NEW_WINDOW_ACTION) return FALSE;
  auto* self = static_cast<CloudLogin*>(data);
  auto* navigation = WEBKIT_NAVIGATION_POLICY_DECISION(decision);
  auto* action = webkit_navigation_policy_decision_get_navigation_action(navigation);
  const char* uri = webkit_uri_request_get_uri(webkit_navigation_action_get_request(action));
  if (self->callback_ != nullptr && MatchesCallback(uri, self->callback_)) {
    webkit_policy_decision_ignore(decision);
    self->Complete(uri);
    return TRUE;
  }
  if (IsSchoolQrPage(uri) && g_strcmp0(uri, self->promoted_qr_uri_) != 0) {
    // The school's iframe polls sis.ustb.edu.cn, then navigates window.top to
    // SSO and OAuth. WebKit can block this cross-origin redirect chain without
    // a gesture in the iframe. The same page also supports top-level login.
    // Keep its URL, cookies and ephemeral WebView; only change its frame.
    g_free(self->promoted_qr_uri_);
    self->promoted_qr_uri_ = g_strdup(uri);
    webkit_policy_decision_ignore(decision);
    self->LoadInMainFrame(uri);
    return TRUE;
  }
  g_autofree gchar* scheme = g_uri_parse_scheme(uri);
  if (g_strcmp0(scheme, "https") != 0 && g_strcmp0(scheme, "http") != 0 &&
      g_strcmp0(scheme, "about") != 0) {
    webkit_policy_decision_ignore(decision);
    return TRUE;
  }
  if (type == WEBKIT_POLICY_DECISION_TYPE_NEW_WINDOW_ACTION) {
    webkit_policy_decision_ignore(decision);
    self->LoadInMainFrame(uri);
    return TRUE;
  }
  return FALSE;
}

gboolean CloudLogin::LoadFailed(WebKitWebView*, WebKitLoadEvent,
                               const char*, GError* error, gpointer data) {
  if (g_error_matches(error, WEBKIT_NETWORK_ERROR, WEBKIT_NETWORK_ERROR_CANCELLED)) return TRUE;
  // Keep signed URLs and authorization codes out of logs and error messages.
  static_cast<CloudLogin*>(data)->Complete(nullptr, "登录网页加载失败，请检查网络后重试");
  return TRUE;
}
