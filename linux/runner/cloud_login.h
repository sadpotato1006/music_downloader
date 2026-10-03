#ifndef QINGTING_CLOUD_LOGIN_H
#define QINGTING_CLOUD_LOGIN_H

#include <flutter_linux/flutter_linux.h>
#include <webkit2/webkit2.h>

class CloudLogin {
 public:
  explicit CloudLogin(GtkWindow* parent) : parent_(parent) {}
  ~CloudLogin();
  void Start(FlMethodCall* call);
  void Cancel();
  static bool MatchesCallback(const char* uri, const char* callback);
  static bool IsSchoolQrPage(const char* uri);

 private:
  friend struct CloudLoginWebViewTest;
  void ConnectWebViewSignals();
  void LoadInMainFrame(const char* uri);
  void StopPendingNavigation();
  void Complete(const char* uri, const char* error = nullptr);
  static gboolean Decide(WebKitWebView*, WebKitPolicyDecision*,
                         WebKitPolicyDecisionType, gpointer);
  static gboolean LoadFailed(WebKitWebView*, WebKitLoadEvent,
                             const char*, GError*, gpointer);
  static void Destroyed(GtkWidget*, gpointer);
  GtkWindow* parent_;
  GtkWidget* window_ = nullptr;
  WebKitWebView* web_view_ = nullptr;
  FlMethodCall* call_ = nullptr;
  gchar* callback_ = nullptr;
  gchar* promoted_qr_uri_ = nullptr;
  gchar* pending_uri_ = nullptr;
  guint navigate_idle_ = 0;
  guint close_idle_ = 0;
};

#endif
