#!/usr/bin/env bash
set -euo pipefail
project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$project_dir"
bundle=${1:-build/linux/x64/release/bundle}
bundle=$(realpath "$bundle")
test -f "$bundle/qingting"
mkdir -p build/linux/native-tests
compile_login_test() {
  clang++ -std=c++14 -Wall -Werror \
    -Ilinux/runner -Ilinux/flutter/ephemeral \
    "$1" linux/runner/cloud_login.cc \
    -L"$bundle/lib" -Wl,-rpath,"$bundle/lib" -lflutter_linux_gtk \
    $(pkg-config --cflags --libs gtk+-3.0 webkit2gtk-4.1) \
    -o "$2"
}
compile_login_test test/linux/cloud_login_callback_test.cc build/linux/native-tests/cloud-login-test
compile_login_test test/linux/cloud_login_webview_test.cc build/linux/native-tests/cloud-login-webview-test
build/linux/native-tests/cloud-login-test
dbus-run-session -- xvfb-run -a python3 tools/linux/test-cloud-login.py \
  build/linux/native-tests/cloud-login-webview-test
# Run only on a disposable D-Bus session and X server; never use real settings.
dbus-run-session -- xvfb-run -a python3 tools/linux/smoke-test.py "$bundle/qingting"
