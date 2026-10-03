#include "cloud_login.h"
#include <glib.h>
#include <initializer_list>

int main(int argc, char** argv) {
  g_test_init(&argc, &argv, nullptr);
  g_test_add_func("/cloud/login/callback", +[]() {
    const char* callback = "https://127.0.0.1:9010/callback";
    g_assert_true(CloudLogin::MatchesCallback(
        "https://127.0.0.1:9010/callback?code=test&state=test", callback));
    const char* rejected[] = {
      "http://127.0.0.1:9010/callback?code=test",
      "https://127.0.0.1:9020/callback?code=test",
      "https://127.0.0.1.evil:9010/callback?code=test",
      "https://127.0.0.1:9010/callback.evil?code=test",
      "https://127.0.0.1:9010/callback/other?code=test",
      "https://user@127.0.0.1:9010/callback?code=test",
      "https://127.0.0.1:9010/callback#code=test",
      "https://127.0.0.1:9010/callback%2fother?code=test",
      "not a URI",
    };
    for (const char* uri : rejected) g_assert_false(CloudLogin::MatchesCallback(uri, callback));
  });
  g_test_add_func("/cloud/login/school-qr", +[]() {
    const char* query = "?appid=test&return_url=https%3A%2F%2Fsso.ustb.edu.cn"
        "%2Fidp%2FauthCenter%2FauthenticateByLck%3FthirdPartyAuthCode%3DmicroQr"
        "%26lck%3Dtest&rand_token=test&embed_flag=1";
    for (const char* page : {"https://sis.ustb.edu.cn/connect/qrpage",
                             "https://sis.ustb.edu.cn:443/connect/qrpage"}) {
      g_autofree gchar* uri = g_strconcat(page, query, nullptr);
      g_assert_true(CloudLogin::IsSchoolQrPage(uri));
    }
    const char* rejected[] = {
      "http://sis.ustb.edu.cn/connect/qrpage",
      "https://sis.ustb.edu.cn:9010/connect/qrpage",
      "https://sis.ustb.edu.cn.evil/connect/qrpage",
      "https://evil/connect/qrpage",
      "https://user@sis.ustb.edu.cn/connect/qrpage",
      "https://sis.ustb.edu.cn/connect/qrpage/other",
      "https://sis.ustb.edu.cn/connect/qrpage.evil",
    };
    for (const char* page : rejected) {
      g_autofree gchar* uri = g_strconcat(page, query, nullptr);
      g_assert_false(CloudLogin::IsSchoolQrPage(uri));
    }
    for (const char* target : {
        "http://sso.ustb.edu.cn/idp/authCenter/authenticateByLck",
        "https://sso.ustb.edu.cn.evil/idp/authCenter/authenticateByLck",
        "https://sso.ustb.edu.cn:9010/idp/authCenter/authenticateByLck",
        "https://user@sso.ustb.edu.cn/idp/authCenter/authenticateByLck",
        "https://sso.ustb.edu.cn/idp/authCenter/authenticateByLck/other",
        "https://sso.ustb.edu.cn/idp/authCenter/authenticateByLck#fragment"}) {
      g_autofree gchar* encoded = g_uri_escape_string(target, nullptr, TRUE);
      g_autofree gchar* uri = g_strconcat(
          "https://sis.ustb.edu.cn/connect/qrpage?return_url=", encoded, nullptr);
      g_assert_false(CloudLogin::IsSchoolQrPage(uri));
    }
    g_autofree gchar* fragment = g_strconcat(
        "https://sis.ustb.edu.cn/connect/qrpage", query, "#fragment", nullptr);
    g_assert_false(CloudLogin::IsSchoolQrPage(fragment));
    g_assert_false(CloudLogin::IsSchoolQrPage(
        "https://sis.ustb.edu.cn/connect/qrpage"));
    g_assert_false(CloudLogin::IsSchoolQrPage(
        "https://sis.ustb.edu.cn/connect/qrpage?return_url=%ZZ"));
    g_assert_false(CloudLogin::IsSchoolQrPage("not a URI"));
    g_assert_false(CloudLogin::IsSchoolQrPage(nullptr));
  });
  return g_test_run();
}
