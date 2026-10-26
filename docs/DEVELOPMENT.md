# 开发与构建

## 环境与检查

- Flutter 3.44.2 / Dart 3.12.2，SDK 约束见 [pubspec.yaml](../pubspec.yaml)。
- Android：Android SDK 和 JDK 17 或更高版本。
- Windows：Visual Studio 的“使用 C++ 的桌面开发”工作负载。
- Linux：对应发行版的原生开发依赖，见下文。

```bash
git clone https://github.com/sadpotato1006/music_downloader.git
cd music_downloader
flutter pub get --enforce-lockfile
dart tools/sync_version.dart --check
flutter analyze
flutter test
```

按平台运行 `flutter run -d windows`、`flutter run -d linux` 或 `flutter run -d <android-device-id>`。源码、脚本和文档使用 UTF-8，遵循 `.editorconfig`。

## Android

调试 APK：`flutter build apk --debug`。

发布 APK 需要在项目根目录创建未纳入版本控制的 `keystore.properties`：

```properties
storeFile=C:/path/to/release.jks
storePassword=your-store-password
keyAlias=your-key-alias
keyPassword=your-key-password
```

执行 `flutter build apk --release`，APK 输出到 `build/app/outputs/flutter-apk/`。更新同一应用时使用相同签名，签名文件和密码不要提交到仓库。

## Windows

云盘登录组件需要 `nuget.exe`，将其加入 `PATH` 后构建：

```powershell
dart tools/sync_version.dart
flutter build windows --release
```

产物位于 `build/windows/x64/runner/Release/`。分发时保留整个目录，包括 DLL 和 `data/`。

生成中文安装程序：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File tools/windows_installer/build-windows-installer.ps1
```

脚本从 `pubspec.yaml` 读取版本，校验 Dart 和 Windows 程序版本一致，输出到 `dist/v<版本>/`，同版本下不再按平台分目录。

Windows 应用内更新发布步骤：

1. 递增 `pubspec.yaml` 的版本号和构建号，运行 `dart tools/sync_version.dart`，将生成文件一同提交。
2. 构建、打包后，将该版本目录中的 `QingTingSetup-v*.exe` 和 `qingting-update.json` 上传到仓库同一个正式 GitHub Release，标签使用 `v<版本>`。清单由打包脚本生成，包含完整版本、安装包名称、大小和 SHA-256；修改安装包后必须重新生成清单。
3. 两个附件全部上传后再发布 Release。应用从 latest 正式版读取更新说明和清单；草稿、预发布不会触发更新。旧版本没有清单时仍可从发布页手动下载安装包。

运行 `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/windows_installer/test-updater.ps1` 验证安装器。测试在 `build/windows-installer-tests/` 创建独立应用和歌曲文件，覆盖升级握手、取消、目录替换、短暂目录句柄锁重试、个人文件保留、启动失败回退和中断恢复，不注册或安装到实际用户目录。Dart 更新测试运行 `flutter test test/app_update_test.dart`。

安装器只有收到应用保存完成并退出的确认才替换文件；新版完成数据加载和首帧后确认启动，随后清理旧程序备份。启动失败会恢复旧程序；因断电等原因中断时，下次运行安装包会读取恢复记录。此机制恢复程序文件，用户数据仍由应用自身的存储备份保护。

## Ubuntu / Debian

Ubuntu 24.04 构建依赖：

```bash
sudo apt-get update
sudo apt-get install -y clang cmake ninja-build pkg-config libgtk-3-dev \
  libstdc++-12-dev libmpv-dev libmimalloc-dev liblzma-dev dpkg-dev \
  libsecret-1-dev libwebkit2gtk-4.1-dev libayatana-appindicator3-dev libpulse-dev \
  xdg-user-dirs fonts-noto-cjk xdg-desktop-portal xdg-desktop-portal-gtk
flutter config --enable-linux-desktop
flutter pub get --enforce-lockfile
flutter run -d linux
```

生成便携包和 DEB：`bash tools/linux/build-linux.sh --deb`。省略 `--deb` 时只生成便携包。输出位于 `dist/`，原始程序目录为 `build/linux/x64/release/bundle/`。可用 `FLUTTER_BIN=/path/to/flutter/bin/flutter` 指定 SDK。

安装包自动声明系统库依赖。产物受 glibc 等系统库版本约束，Ubuntu 24.04 产物不保证兼容旧发行版。ARM64 需要对应架构的主机及工具链，尚需单独验证。

## Arch Linux

在 x86_64 Arch 中安装依赖，以普通用户构建：

```bash
sudo pacman -Syu --needed base-devel clang cmake ninja pkgconf gtk3 mpv \
  mimalloc libsecret webkit2gtk-4.1 libayatana-appindicator libpulse \
  xdg-user-dirs xdg-desktop-portal xdg-desktop-portal-gtk git curl unzip xz
flutter config --enable-linux-desktop
bash tools/arch/build-arch.sh
```

脚本读取 `pubspec.yaml` 版本，生成带校验信息的 PKGBUILD，并调用 `makepkg`。安装包及 SHA-256 文件输出到 `dist/`。`makepkg` 必须由普通用户运行。

Arch 和 Ubuntu 使用各自的源码副本与构建缓存；不要将 Ubuntu 便携包重打包为 Arch 包。系统库 ABI 升级后应重新构建。

## Linux 集成验证与 CI

Release 构建后执行 `bash tools/linux/test-native.sh`，另需：

- Ubuntu：`python3-gi xdotool xvfb dbus-x11 gnome-keyring openssl`。
- Arch：`python-gobject xdotool xorg-server-xvfb dbus mesa gnome-keyring openssl`。
- 音频验证：`pulseaudio`、`pactl`。

测试使用临时数据目录、独立运行目录与密钥环，在 Xvfb 启动后创建 D-Bus 会话以正确传递显示环境；覆盖扫码回调、WebKitGTK 导航、MPRIS、托盘、单实例和退出保存。扫码使用本地模拟服务；真实微信扫码及物理蓝牙切换需在桌面上另行验证。

手动工作流 [Build Linux](../.github/workflows/linux.yml) 和 [Build Arch Linux](../.github/workflows/arch.yml) 会分析、测试和打包，产物从对应 Actions 运行记录下载。

WSL 建议使用 Linux 文件系统中的独立源码副本，避免与 Windows 共用 Flutter SDK、`.dart_tool/` 和 `build/`。

## 模块边界与回归检查

`AppController` 负责跨模块协调及兼容现有 UI 调用，不持有下载工作线程、在线搜索请求版本或设置保存定时器：

| 模块 | 职责 |
| --- | --- |
| `lib/download_controller.dart` | 下载任务快照、并发调度、暂停/取消/重试、文件名预留、进度通知、任务持久化及退出等待 |
| `lib/download_transfer_service.dart` | 流式 HTTP 与文件写入、Range/If-Range、Content-Range 和音频头校验；不操作曲库 |
| `lib/music_search_controller.dart` | 在线搜索状态、过期结果丢弃及销毁后的回调隔离 |
| `lib/source_request_queue.dart` | 搜索、播放解析和下载解析共用的串行请求与成功请求间隔；跳过已过期任务 |
| `lib/settings_persistence.dart` | 合并延迟保存、失败重试、保存期间的新编辑及退出刷新 |
| `lib/artwork_service.dart` | 封面网络/本地读取、大小限制、取消传递与 MIME 识别 |
| `lib/*_source.dart` | 各来源搜索/解析协议；`RefreshableDownloadMusicSource` 用于强制刷新失效链接 |
| `lib/controller/` | 播放、曲库、同步、歌曲信息处理等应用协调；下载完成后的入库和标签写入仍在此层 |

目录扫描共用进行中的扫描任务，完成时重建曲库列表快照；对当前目录内文件已不存在、且未被下载或歌曲信息写入持有的记录执行清理，并持久保存关联列表。同步会等待已有扫描结束后再执行一次新扫描，异常退出同步时也尝试扫描；退出保存会等待当前扫描收尾。对应回归覆盖无新增歌曲、外部目录保留、目录不可访问、未完成下载、同步中断以及扫描与同步交错的情况。

下载不接收 UI 或曲库状态引用，只通过回调执行准备、标签处理和入库。下载任务继续使用原有 JSON 格式及 `track` 标识，老版本暂停任务无需迁移。单次链接刷新失败会保留失败状态，不无限重试。HTTP 416 只有在长度及强验证信息一致、且本地内容可识别为音频时才接受为完整文件。

软件更新的版本、错误提示和检查按钮使用可自动换行的同一工具行；本地筛选按钮在已有关键词时调用 `setLibraryQuery('')` 清空筛选，同时作废旧歌词搜索结果，未筛选时才打开搜索面板。界面回归覆盖按钮同行布局、筛选清除、再次搜索以及排序和历史保留。

重点回归命令：

```bash
flutter test test/download_controller_test.dart test/download_transfer_service_test.dart
flutter test test/controller_boundaries_test.dart test/app_controller_test.dart test/library_refresh_test.dart
flutter test test/xiagebao_source_test.dart test/my_free_mp3_source_test.dart
```

下歌宝使用公开搜索 `/s/<关键词>` 与详情 `/music/<ID>` 页面；支持页面直接音频和 `<audio>` / `<source>`，共享已有 HTML 元数据解析能力。其来源 ID 使用 `xgb:` 前缀，避免与歌曲宝数字 ID 混淆。验证页返回错误，网盘 `/dp/` 与外部分享链接不进入音频候选。解析与拒绝路径有离线测试；2026-10-26 当前开发网络的直接请求和浏览器均触发 Cloudflare 验证，真实搜索、播放和下载尚未完成联调，发布验证时应在可正常访问的网络再检查。

本次版本为 `1.7.0+35`。Android APK、Windows 安装程序与便携 ZIP、Linux DEB、Arch 安装包与便携包集中存放在 `dist/v1.7.0/`；Linux 包需使用独立 Linux 源码副本和缓存构建，不能复用 Windows `.dart_tool/`。

## 代码与资料

| 目录 | 内容 |
| --- | --- |
| `lib/ui/` | 搜索、曲库、播放、设置等界面 |
| `lib/controller/` | 搜索、下载、播放、曲库与同步逻辑 |
| `test/` | Dart / Flutter 自动化测试 |
| `android/`、`windows/`、`linux/` | 各平台原生工程 |
| `tools/` | 打包脚本与平台集成检查 |

发布记录见 [CHANGELOG](../CHANGELOG.md)。云盘接入的独立技术资料见[迁移说明](USTB_ANYSHARE_BACKEND_MIGRATION.md)。
