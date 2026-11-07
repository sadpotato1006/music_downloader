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

应用内更新发布步骤（Windows / Android）：

1. 递增 `pubspec.yaml` 的版本号和构建号，运行 `dart tools/sync_version.dart`，将生成文件一同提交。
2. 构建 Windows 安装包和使用原签名的 Android APK，把 APK 命名为 `QingTing-v<版本>-build<构建号>.apk`，放入同一 `dist/v<版本>/` 目录。在 Windows 打包脚本完成后执行 `dart run tools/build_update_manifest.dart`，生成同时含 `windows-x64` 与 `android` 的 `qingting-update.json`。清单保持 schemaVersion 1，旧 Windows 客户端仍可读取；修改安装包后必须重新生成清单和发行文件校验清单。
3. 将 EXE、APK、`qingting-update.json` 及 Linux 安装包上传到仓库同一个正式 GitHub Release，标签使用 `v<版本>`。附件全部上传后再发布。三端从 latest 正式版读取更新说明；草稿、预发布不会触发更新。Android / Linux 遇到旧发布没有清单时按标签检查新版并提供发布页下载入口。

`AppUpdateController` 共用检查、启动提示、取消和错误状态。Windows 保留升级握手和回退；Android 共用下载大小与 SHA-256 校验，原生桥仅接受应用私有 `files/updates/` 中、应用标识/版本/签名匹配的 APK，通过只读 FileProvider URI 交给系统安装器。安装权限仅在用户点击安装后申请，授权后可重试；安装器返回后解除应用退出准备状态。Linux 只提示并打开具体版本发布页，由用户选择适合发行版的包。

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
| `lib/settings_controller.dart` | 设置快照的唯一所有者、设置变更与统一保存入口、独立的主题通知 |
| `lib/settings_platform_service.dart` | 下载目录校验、系统目录选择器、权限设置和外部链接；可注入替换 |
| `lib/song_file_access.dart` | 歌曲文件的并发读取、独占写入、删除及云同步协调；事件唤醒等待者 |
| `lib/ui/settings.dart`、`lyrics_settings.dart`、`linux_desktop_settings.dart` | 独立 Dart 库；设置界面不再依赖 `AppController` 或 `main.dart` 的私有成员 |
| `lib/ui/theme.dart`、`components.dart` | 独立主题与基础组件；主题范围只监听主题 ID，不监听播放或下载状态 |
| `lib/ui/settings_integration.dart` | 组装设置页的曲库工具、同步入口及更新组件，集中处理跨功能依赖 |
| `lib/ui/selected_builder.dart`、`lib/controller/view_state.dart` | 按不可变状态投影更新导航、迷你播放器和活动页面；提示浮层单独更新 |
| `lib/startup_work_queue.dart` | 首帧与自动播放优先，后台维护分阶段执行；退出时取消排队任务并等待当前任务收尾 |
| `lib/snapshot_delta.dart` | 大曲库及长队列的有界累计增量，绑定完整快照摘要，变化过多时回到完整快照 |
| `lib/artwork_service.dart` | 封面网络/本地读取、大小限制、取消传递与 MIME 识别 |
| `lib/*_source.dart` | 各来源搜索/解析协议；`RefreshableDownloadMusicSource` 用于强制刷新失效链接 |
| `lib/controller/` | 播放、曲库、同步、歌曲信息处理等应用协调；下载完成后的入库和标签写入仍在此层 |

设置变更统一使用 `preferences.update` / `updateAndSave` 或对应领域方法；只有启动恢复使用 `restore`。音量、搜索历史、云盘设置与界面设置共用同一保存队列，避免较早的异步快照覆盖较新的编辑。`AppController.settings` 和原有设置方法暂时作为兼容入口；新增设置组件直接依赖 `SettingsController`。下载并发变化的调度和更新检查的副作用仍由应用协调层处理。

设置的 `saveState` 独立报告待保存、保存中和错误，不触发主题刷新。自动或手动保存失败都会记录日志，并在设置/歌词/同步界面显示重试入口；界面事件捕获保存异常，保留选择和输入。重试保存最新快照，成功后撤去错误提示；“启动时检查更新”的运行时策略只在设置持久化成功后应用。

导航只比较选中页面，迷你播放器只比较当前歌曲、播放状态和队列是否为空。活动页面比较自己的状态投影，隐藏页面在重新进入时读取最新状态；歌词位置和下载进度仍使用专门的通知。搜索历史按内容比较，避免设置复制时生成的新列表引起无关刷新。提示消息使用独立 `ValueNotifier`，出现和消失都不重建整个主界面。

桌面／悬浮歌词保留当前歌词文本及解析列表，内容变化时才调用共用解析器；进度更新直接在该列表中二分定位，避免重复整理文本和查询解析缓存。关闭浮层时跳过歌词解析与定位，重新开启时读取当前歌曲及最新歌词。时间偏移实时应用，切歌、歌词补全／清除和向前／向后拖动不依赖上次定位结果。

歌词进度条使用局部拖动预览，松手后才向播放器发送跳转；原生进度尚未到达时保留预览，最多等待两秒。歌曲 ID 与 URI 共同标识拖动组件，切歌销毁旧操作。歌词列表只在用户拖动或滚轮滚动时暂停自动跟随，自动居中不触发暂停；恢复按钮及切歌重新启用跟随。

歌曲卡片的准备／失败状态按来源与歌曲 ID 或本地路径定位，沿用播放请求版本丢弃过期回调。播放状态进入搜索及曲库的状态投影，播放时间仍走独立通知。搜索的空结果与请求失败分开记录，重试和换源复用已提交关键词。

`PlaybackService.health` 按歌曲 ID 与 URI 报告缓冲和运行时错误，迷你播放器、歌词页及当前歌曲卡片分别显示状态；旧歌曲的状态不会作为当前歌曲状态展示。失败后由用户重试，不无限自动循环。当前会话最近 64 个在线解析结果保留来源，用于重试时重新获取播放链接；恢复的旧队列或本地歌曲可重新打开已有媒体。

达到 512 首时，曲库元数据快照交给 `LibraryQueryWorker` 的独立 isolate，拼音索引、匹配及排序在后台执行。工作线程复用索引及排序，只有曲库变化时重新发送轻量元数据，不传封面或歌词正文；主线程只合并匹配索引及歌词命中集合。请求串行合并，只发布仍符合当前曲库、关键词和排序方式的结果，切回小曲库或销毁时释放后台缓存。小曲库保留同步查询。`libraryViewReady` 可供测试等待后台元数据结果，歌词命中仍按原有异步通知增量更新。可运行 `dart run tools/benchmark_library_queries.dart` 测量合成曲库冷／热查询及主线程定时器响应，这不代表真机帧率。

Linux 桌面设置不再每五秒轮询；仅在设置页激活、应用恢复前台及成功修改设置后读取。隐藏页面不发起读取，重叠刷新合并，写入前使旧读取失效；读取失败保留手动重试入口。

启动先恢复必需数据并显示首页，实际应用通过 `waitForStartupFrame` 提供首帧边界；随后优先自动播放。维护任务按顺序启动下载调度、恢复下载入库、补全本地元数据、延迟标签写入、云盘恢复与同步，阶段间让出 300 毫秒。长任务内部已有的并发限制保持生效。`startupMaintenanceDone` 可用于需要等待维护完成的调用；`bootstrap()` 仅代表必需数据已就绪。退出会丢弃未启动的维护任务，不让后台队列阻止首帧等待取消。

### 大曲库与队列增量保存

少于 512 项时保持原有完整 JSON 保存；达到阈值后，单曲修改及队列游标/随机开关更新优先写入 `downloads.json.delta` 或 `queue.json.delta`。增量是相对完整快照的累计覆盖，最多 128 个变更条目且限制编码大小；大量重排、批量修改或缩小曲库时写入完整快照。完整快照和增量都沿用原子替换及 `.bak` 恢复机制，退出刷新等待整个增量保存操作。

SHA-256 将增量绑定到对应完整文件；完整快照提交后遗留的旧增量不会再次应用。恢复原快照内容时显式提交空覆盖，防止历史修改重放。大型 JSON 编解码与摘要计算使用后台 isolate。增量及备份都损坏、或增量存在而基础文件丢失时阻止覆盖并保留文件；可用备份仍按原有恢复机制处理。

迁移旧数据无需转换工具，首次读取旧 JSON 即可。手动备份/迁移应用数据目录时应同时保留完整 JSON、`.delta` 和各自 `.bak` 文件；旧程序不理解增量文件，只能读到完整快照时的状态。

曲库及同步通过 `SongFileAccess` 申请文件访问，不再直接共享读写集合。成功申请后必须在 `finally` 中释放；同步先禁止新操作，再等待已有读、写和删除完成。同步导入已下载歌曲的内部读取保留专用通道，避免等待自身；关闭时唤醒等待者。播放文件句柄、下载路径预留及业务操作顺序仍由原有模块负责，不能将该组件当作操作系统文件锁。

这次拆分没有将整个 `AppController` 重写为多个独立控制器；曲库、播放队列和同步流程仍使用 `part` 扩展。后续拆分应沿用明确的状态所有权和组合接口，不应将共享字段搬到另一个全局容器。

目录扫描共用进行中的扫描任务，完成时重建曲库列表快照；对当前目录内文件已不存在、且未被下载或歌曲信息写入持有的记录执行清理，并持久保存关联列表。同步会等待已有扫描结束后再执行一次新扫描，异常退出同步时也尝试扫描；退出保存会等待当前扫描收尾。对应回归覆盖无新增歌曲、外部目录保留、目录不可访问、未完成下载、同步中断以及扫描与同步交错的情况。

下载不接收 UI 或曲库状态引用，只通过回调执行准备、标签处理和入库。下载任务继续使用原有 JSON 格式及 `track` 标识，老版本暂停任务无需迁移。单次链接刷新失败会保留失败状态，不无限重试。HTTP 416 只有在长度及强验证信息一致、且本地内容可识别为音频时才接受为完整文件。

设置按播放、下载与本地、外观与歌词、同步、软件更新分组；Linux 桌面设置独立显示。桌面内容居中并限制为 960，宽屏将选项标签与控件排成一行，窄屏自动上下排列；目录编辑控制器和保存/重试逻辑保持共用。源代码与联系作者保留原内容。

软件更新的版本、错误提示、检查按钮和“已是最新正式版”使用可自动换行的同一工具行；删除启动检查副标题、诊断副标题及顶部标语。歌曲卡片删除“正在播放”文字，当前歌曲仍高亮，桌面网格恢复 72 高度并跟随字体缩放；仅有第三行时使用紧凑行距，保留准备、缓冲、失败及重试反馈。

本地筛选按钮在已有关键词时调用 `setLibraryQuery('')` 清空筛选，同时作废旧歌词搜索结果，未筛选时才打开搜索面板。界面回归覆盖按钮同行布局、筛选清除、再次搜索以及排序和历史保留。

重点回归命令：

```bash
flutter test test/download_controller_test.dart test/download_transfer_service_test.dart
flutter test test/controller_boundaries_test.dart test/app_controller_test.dart test/library_refresh_test.dart
flutter test test/settings_controller_test.dart test/settings_view_test.dart test/song_file_access_test.dart
flutter test test/startup_work_queue_test.dart test/snapshot_delta_storage_test.dart
flutter test test/xiagebao_source_test.dart test/my_free_mp3_source_test.dart
```

下歌宝使用公开搜索 `/s/<关键词>` 与详情 `/music/<ID>` 页面；支持页面直接音频和 `<audio>` / `<source>`，共享已有 HTML 元数据解析能力。其来源 ID 使用 `xgb:` 前缀，避免与歌曲宝数字 ID 混淆。验证页返回错误，网盘 `/dp/` 与外部分享链接不进入音频候选。解析与拒绝路径有离线测试；2026-10-26 当前开发网络的直接请求和浏览器均触发 Cloudflare 验证，真实搜索、播放和下载尚未完成联调，发布验证时应在可正常访问的网络再检查。

本次版本为 `1.7.1+41`，各平台安装包集中存放于 `dist/v1.7.1/`。Linux 包需使用独立 Linux 源码副本和缓存构建，不能复用 Windows `.dart_tool/`。

## 代码与资料

### 主题配色

刷新率检测面板及其动画控制器、帧采样和统计逻辑已整体移除，玻璃组件和桌面图标换色服务也已删除。Android 的显示模式请求负责实际高刷支持，继续保留；旧桌面别名仅用于升级快捷方式兼容。复用 Linux 构建副本时，`lib/`、`test/`、`assets/` 必须同步删除主工作区已移除的文件，避免残留废弃源码。

`lib/ui/theme.dart` 集中管理六套浅色主题、主题缓存、实色面板与导航按钮。主题只改变强调色、选中背景和页面背景；无全屏渐变绘制、背景滤镜或半透明玻璃面板。页面和弹窗从 `Theme` 读取配色，播放与同步进度通知不会重新创建主题数据。

复用设置字段 `theme`，支持 `lightGreen`、`skyBlue`、`lavender`、`rose`、`apricot`、`graphite`，默认青竹。`normalizeAppTheme` 对缺失、未知和错误类型的持久化值回退；旧 `liquidGlassEnabled` 被忽略且不再写出。设置通过现有延迟保存队列持久化，主题切换不销毁页面；下载路径仅在保存值实际变化时同步，避免丢失未保存输入。

`flutter test test/app_controller_test.dart --plain-name theme` 覆盖迁移、持久化、六套强调色文字对比度、即时切换和编辑状态保留、手机/桌面布局、无障碍与绘制记录复用。添加 `--dart-define=THEME_SCREENSHOTS=true --plain-name "theme layout"` 在 `.tooling/` 输出六套主题预览；中文预览使用 Windows 微软雅黑。

导航 `LayoutBuilder` 位于固定高度 `SizedBox` 内，以紧约束阻止动画重建向外传播布局失效；外框和内容独立绘制。DPR3、模拟 120Hz 下检查固定外框和播放器绘制记录逐帧复用，但这不代表物理设备实际帧率测试。

### Android 固定图标与升级

图标恢复为原有 `mipmap-*/ic_launcher.png`。`QingTingActivity` 是唯一带 MAIN/LAUNCHER 的真实入口，始终启用。先前版本的别名只保留为无 LAUNCHER 的兼容入口，方便既有显式快捷方式启动；应用不再调用 `setComponentEnabledSetting(s)`，避免禁用正在使用的入口触发系统关闭任务。旧别名的已禁用状态不会影响新的真实桌面入口。Flutter 调试也可直接识别真实入口。

对外发布号为 `1.7.1`，Android `versionCode` 继续递增为 41，安装时可覆盖前一构建并保留数据。界面只显示发布号，诊断导出和更新清单保留完整构建号。恢复使用固定图标后，不再有图标同步通道或前台/后台切换图标任务。

### 导航与刷新率

`HomeShell` 区分按钮发起的目标页与手势切页：程序动画经过的中间页不回写 `selectedIndex`，只有目标改变才重新驱动动画，无关控制器通知不会打断动画。手势开始即接管滚动；导航高亮直接读取 `PageController.page`，不单独启动第二条移动动画。高亮位置通过 `Transform.translate` 更新，固定 `Positioned` 的布局坐标，避免每帧重新布局；高亮内容作为 `AnimatedBuilder.child` 复用，并单独隔离绘制。已访问页面通过 keep-alive 保存状态，并使用 `RepaintBoundary` 隔离绘制。状态栏安全区包在胶囊外侧。

Android 在 `QingTingActivity` 恢复、获得焦点和显示模式变化时，请求当前分辨率下最高刷新率模式，省电时撤回偏好。Windows Flutter 引擎通过 `DwmGetCompositionTimingInfo` 获取帧间隔，应用不添加固定频率定时器。Linux 当前 SDK 的 GTK 嵌入层未提供 vsync 回调，实际走 `VsyncWaiterFallback` 的 1/60 秒调度；报告的显示器刷新率高于 60Hz 也不能据此认为动画已跑满高刷。本轮保留官方引擎与原有线程模型。

依据本项目 Flutter 3.44.2 对应引擎源码：[Windows 帧间隔](https://github.com/flutter/flutter/blob/c9a6c484230f8b5e408ec57be1ef71dee1e77020/engine/src/flutter/shell/platform/windows/flutter_windows_engine.cc)、[Linux 引擎初始化](https://github.com/flutter/flutter/blob/c9a6c484230f8b5e408ec57be1ef71dee1e77020/engine/src/flutter/shell/platform/linux/fl_engine.cc)、[60Hz 回退](https://github.com/flutter/flutter/blob/c9a6c484230f8b5e408ec57be1ef71dee1e77020/engine/src/flutter/shell/common/vsync_waiter_fallback.cc)。

已移除诊断页的动画检测卡片。`navigation keeps the requested destination` 回归使用 60/90/120/144Hz 模拟帧时钟，验证中间页、无关通知和快速改选；实际高刷流畅度仍需目标设备实测。

先前原生验证：Ubuntu 的默认 OpenGL 路径通过；Arch 在 Xvfb 无显示器环境中出现退出超时，使用 `FLUTTER_LINUX_RENDERER=software` 后原生流程通过。发行包继续使用默认官方引擎，未将软件渲染设为默认；Arch 的物理显示器 / GPU 呈现和退出仍需目标机器验证，不能将软件模式通过视为 OpenGL 问题已修复。

| 目录 | 内容 |
| --- | --- |
| `lib/ui/` | 搜索、曲库、播放、设置等界面 |
| `lib/controller/` | 搜索、下载、播放、曲库与同步逻辑 |
| `test/` | Dart / Flutter 自动化测试 |
| `android/`、`windows/`、`linux/` | 各平台原生工程 |
| `tools/` | 打包脚本与平台集成检查 |

发布记录见 [CHANGELOG](../CHANGELOG.md)。云盘接入的独立技术资料见[迁移说明](USTB_ANYSHARE_BACKEND_MIGRATION.md)。
