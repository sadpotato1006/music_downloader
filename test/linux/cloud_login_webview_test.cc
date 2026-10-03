#include "cloud_login.h"

namespace {

const char* kCallback = "https://127.0.0.1:9010/callback";

struct LoginState {
  bool callback = false;
  bool failed = false;
  guint qr_navigations = 0;
  guint qr_commits = 0;
};

gboolean ObserveNavigation(WebKitWebView*, WebKitPolicyDecision* decision,
                           WebKitPolicyDecisionType type, gpointer data) {
  if (type != WEBKIT_POLICY_DECISION_TYPE_NAVIGATION_ACTION) return FALSE;
  auto* state = static_cast<LoginState*>(data);
  auto* navigation = WEBKIT_NAVIGATION_POLICY_DECISION(decision);
  auto* action = webkit_navigation_policy_decision_get_navigation_action(navigation);
  const char* uri = webkit_uri_request_get_uri(webkit_navigation_action_get_request(action));
  if (CloudLogin::IsSchoolQrPage(uri)) ++state->qr_navigations;
  if (CloudLogin::MatchesCallback(uri, kCallback)) state->callback = true;
  // Observe first, then let the real CloudLogin policy handle the navigation.
  return FALSE;
}

void WaitForCallback(LoginState* state) {
  const gint64 deadline = g_get_monotonic_time() + 20 * G_TIME_SPAN_SECOND;
  while (!state->callback && !state->failed && g_get_monotonic_time() < deadline) {
    while (g_main_context_iteration(nullptr, FALSE)) {}
    g_usleep(1000);
  }
  g_test_message("QR navigations: %u; main-frame QR commits: %u",
                 state->qr_navigations, state->qr_commits);
  g_assert_false(state->failed);
  g_assert_true(state->callback);
}

}  // namespace

struct CloudLoginWebViewTest {
  static void Open(CloudLogin* login, LoginState* state) {
    login->callback_ = g_strdup(kCallback);
    login->window_ = gtk_window_new(GTK_WINDOW_TOPLEVEL);
    g_autoptr(WebKitWebContext) context = webkit_web_context_new_ephemeral();
    login->web_view_ = WEBKIT_WEB_VIEW(g_object_new(WEBKIT_TYPE_WEB_VIEW,
        "web-context", context, "is-ephemeral", TRUE, nullptr));
    gtk_container_add(GTK_CONTAINER(login->window_), GTK_WIDGET(login->web_view_));
    g_signal_connect(login->window_, "destroy", G_CALLBACK(CloudLogin::Destroyed), login);
    g_signal_connect(login->web_view_, "decide-policy", G_CALLBACK(ObserveNavigation), state);
    g_signal_connect(login->web_view_, "load-changed",
        G_CALLBACK(+[](WebKitWebView* view, WebKitLoadEvent event, gpointer data) {
          if (event == WEBKIT_LOAD_COMMITTED &&
              CloudLogin::IsSchoolQrPage(webkit_web_view_get_uri(view))) {
            ++static_cast<LoginState*>(data)->qr_commits;
          }
        }), state);
    g_signal_connect(login->web_view_, "load-failed",
        G_CALLBACK(+[](WebKitWebView*, WebKitLoadEvent, const char*, GError* error,
                       gpointer data) -> gboolean {
          if (!g_error_matches(error, WEBKIT_NETWORK_ERROR, WEBKIT_NETWORK_ERROR_CANCELLED)) {
            static_cast<LoginState*>(data)->failed = true;
            g_test_message("Unexpected load error (domain %u, code %d)", error->domain, error->code);
          }
          return FALSE;
        }), state);
    login->ConnectWebViewSignals();
  }

  static void ScanRedirect() {
    LoginState state;
    CloudLogin login(nullptr);
    Open(&login, &state);
    g_assert_true(webkit_web_view_is_ephemeral(login.web_view_));
    auto* context = webkit_web_view_get_context(login.web_view_);
    auto* manager = webkit_web_context_get_website_data_manager(context);
    const char* proxy_uri = g_getenv("QINGTING_LOGIN_TEST_PROXY");
    const char* certificate_path = g_getenv("QINGTING_LOGIN_TEST_CERT");
    g_assert_nonnull(proxy_uri);
    g_assert_nonnull(certificate_path);
    auto* proxy = webkit_network_proxy_settings_new(proxy_uri, nullptr);
    webkit_website_data_manager_set_network_proxy_settings(
        manager, WEBKIT_NETWORK_PROXY_MODE_CUSTOM, proxy);
    webkit_network_proxy_settings_free(proxy);
    g_autoptr(GError) error = nullptr;
    g_autoptr(GTlsCertificate) certificate = g_tls_certificate_new_from_file(certificate_path, &error);
    g_assert_no_error(error);
    // Trust only this disposable fixture certificate inside this test WebView.
    // Production continues to use normal TLS validation.
    const char* hosts[] = {"sis.ustb.edu.cn", "sso.ustb.edu.cn", "yunpan.ustb.edu.cn"};
    for (const char* host : hosts) {
      webkit_web_context_allow_tls_certificate_for_host(context, certificate, host);
    }
    gtk_widget_show_all(login.window_);
    webkit_web_view_load_uri(login.web_view_, "https://sso.ustb.edu.cn/ac/");
    WaitForCallback(&state);
    // The QR iframe must become the main document, retaining its full URL and
    // SSO cookies, and its server redirects must reach the intercepted callback.
    g_assert_cmpuint(state.qr_navigations, ==, 2);
    g_assert_cmpuint(state.qr_commits, ==, 1);
    g_assert_cmpuint(login.navigate_idle_, ==, 0);
    login.Cancel();
  }

  static void CancelPendingNavigation() {
    LoginState state;
    CloudLogin login(nullptr);
    Open(&login, &state);
    login.LoadInMainFrame("https://sso.ustb.edu.cn/ac/");
    g_assert_cmpuint(login.navigate_idle_, !=, 0);
    login.Cancel();
    g_assert_cmpuint(login.navigate_idle_, ==, 0);
    g_assert_null(login.pending_uri_);
    g_assert_null(login.web_view_);
    while (g_main_context_iteration(nullptr, FALSE)) {}
    g_assert_cmpuint(state.qr_navigations, ==, 0);
    g_assert_false(state.callback);
  }
};

int main(int argc, char** argv) {
  gtk_init(&argc, &argv);
  g_test_init(&argc, &argv, nullptr);
  g_test_add_func("/cloud/login/webview/scan-redirect", CloudLoginWebViewTest::ScanRedirect);
  g_test_add_func("/cloud/login/webview/cancel-pending", CloudLoginWebViewTest::CancelPendingNavigation);
  return g_test_run();
}
