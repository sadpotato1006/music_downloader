This directory contains `flutter_inappwebview_android` 1.1.3 from pub.dev.
The upstream Apache 2.0 license is included as `LICENSE`.

Local change: `android/build.gradle` uses
`proguard-android-optimize.txt` in both build types. Android Gradle Plugin 9
rejects the upstream `proguard-android.txt` setting, even for debug builds.

When upgrading the plugin, remove the `dependency_overrides` entry in the
root `pubspec.yaml` once an upstream release supports AGP 9.
