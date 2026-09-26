# 青听

<p align="center">
  <img src="assets/logo.jpg" alt="青听 Logo" width="120">
</p>

青听是一款使用 Flutter 开发的个人音乐工具，支持在 Android、Windows 和 Linux 上搜索、播放、下载及管理音乐。Linux 当前提供基础桌面版。

当前版本：`v1.5.0+32`

> 本项目仅解析公开可访问的网页内容，不处理登录、付费、验证码、DRM 或其他访问限制。

## 功能

### 搜索与下载

- 支持“歌曲宝”和“MY FREE MP3”两个在线音乐源，并可在搜索页一键切换
- 搜索歌曲并查看历史搜索记录，切换来源后会自动重新搜索当前关键词
- 在线播放，或将歌曲加入下载队列
- 在线歌曲拿到音频地址后即可播放，缺失歌词在后台补全；歌词服务缓慢或失败不会阻塞播放
- 连续选歌、切换到本地歌曲或清空队列后，较早的在线解析结果不会抢回播放，也不会覆盖当前操作提示
- 适配歌曲宝新版接口，按播放或下载用途解析音频地址，修复缺少用途参数导致的 HTTP 422 错误
- 下载任务会立即显示“已加入下载队列”，完成或失败后继续显示结果通知，并拦截同一首歌曲的重复下载
- 音频下载完成后，封面缓存失败不会影响歌曲入库；曲库保存失败会显示“已下载 · 待保存到曲库”，可单独重试保存，重启后自动恢复入库，无需重新下载音频
- 连续提交搜索时仅采用最后一次请求结果，较早返回的结果不会覆盖当前关键词
- 显示下载进度，支持暂停、取消和失败重试；未完成任务会跨重启保留
- 并发创建下载任务时会串行预留目标路径；同名歌曲或尚未落盘的排队任务不会写入同一个文件
- 同一下载任务始终只会由一个 worker 执行，快速暂停并重试也不会并发写入同一个文件
- 取消操作覆盖音频下载、封面获取和 ID3 写入后的完整处理流程，已取消任务不会被重新标记为完成
- 暂停或异常中断后优先通过 HTTP Range 断点续传；服务器不支持或 ETag/Last-Modified 已变化时安全回退为重新下载
- 下载结束时校验实际字节数；断点文件过大或响应提前结束时拒绝标记完成，并安全重试或保留断点
- 下载封面采用最大 5 MiB 的流式读取；超限会立即中止封面请求，但不影响歌曲文件继续完成
- 下载连接设置默认连接、发送和分块接收超时，异常服务器不会永久占用下载槽
- 优先选择 MP3；仅找到其他格式时会先征求确认
- 下载 MP3 后写入歌名、歌手、专辑、歌词和封面等 ID3 信息
- MY FREE MP3 缺少内置歌词时会通过 LRCLIB 匹配歌词，再写入下载文件
- MY FREE MP3 的生成任务会合并同一歌曲的并发请求；生成地址仅短时缓存并限制数量，过期后自动重新获取
- 下载完成后默认通过 Apple iTunes Search API 校验专辑名称，Apple 无可靠结果时再使用 MusicBrainz，均失败时保留音乐网站原值

### 播放与歌词

- 播放、暂停、上一首、下一首、单曲循环和随机队列
- 查看、调整和持久化播放队列；队列播完后会重新随机排序并自动开始下一轮，大型本地列表按需读取歌曲元数据
- 连续点击“下一首播放”时，尚未完成的在线解析或本地读取采用最后一次点击；较早请求不会覆盖新请求的准备状态或提示，清空队列后也不会重新加入歌曲
- 完整歌词页支持同步滚动、点击跳转和拖动播放进度；支持 LRC 时间偏移，无时间、部分时间、越界时间或拖到进度末端都不会误触发切歌
- 歌词页的时间和进度条独立刷新，歌词区域只在高亮行或歌曲信息变化时更新，减少播放期间的重复构建
- Android 支持通知栏与锁屏媒体控制
- Android 和 Windows 在当前蓝牙音频断开或切换设备时自动暂停；连接蓝牙时不会暂停
- Windows 支持置顶桌面歌词、自由拖动和鼠标穿透锁定；锁定后悬浮歌词可通过开锁图标一键解锁
- Windows 会记住主窗口上次的正常尺寸，下次启动时自动恢复
- Android 支持系统悬浮歌词，需要授予悬浮窗权限

### 本地音乐

- 扫描下载目录，将已有歌曲导入本地曲库
- 按歌名、歌手、专辑、歌词、拼音或拼音首字母搜索
- 本地歌词搜索以受控并发读取文件并分批刷新结果；切换关键词会停止旧查询的后续读取，歌词缓存设有条目数和文本大小上限，缓存淘汰不会丢失当前查询已找到的歌曲
- 编辑本地歌曲的歌名、歌手、专辑、歌词和封面
- 手动选择本地封面时，读取前检查 5 MiB 大小限制，并限制实际读取字节数，避免大文件占用过多内存
- 通过歌曲的“更多”菜单收藏或取消收藏，创建自定义歌单并查看最近播放
- 打开歌曲文件或所在目录
- 可选择删除歌曲文件本身，或仅删除曲库记录；Windows 会将歌曲移入回收站，Android 和 Linux 会直接永久删除，删除前都会明确说明影响并要求确认
- 删除歌曲文件时会同步移除播放队列中的同路径项目；若正在播放该歌曲，会先停止并在成功删除后接续播放下一首
- 文件删除成功后，队列、曲库和“我的音乐”会独立保存；其中一项保存或接续播放失败时不会阻断其他清理步骤，并会给出明确提示
- 启动时以受控并发补全本地歌曲元数据，复用路径索引并集中合并结果，避免逐首遍历和复制整个曲库；补全过程中的编辑、删除和重新导入优先保留
- 扫描封面使用完整文件路径和哈希缓存键，不同子目录中的同名歌曲及长文件名不会共用封面；继续兼容已有缓存并自动回收不再使用的旧封面
- 启动时并行恢复曲库、歌单、播放队列和下载任务，减少数据较多时的等待
- 下载目录递归扫描使用受控并发读取新歌曲元数据，并按规范化路径避免重复导入
- 安全批量补全缺失专辑：显示逐首进度和结果统计，支持停止任务；低置信度候选会原子保存，可稍后或重启后集中审阅
- 专辑匹配综合歌名、歌手、时长、中英日韩版本词、候选分差及 Apple/MusicBrainz 跨来源证据，避免误写现场版、伴奏、混音版或精选集
- 设置、曲库、歌单、播放队列、下载任务和待确认专辑采用原子写入并保留上一代备份，文件异常时自动恢复
- 曲库、歌单、播放队列和任务的密集保存请求会合并为最新待保存快照，使用紧凑 JSON 减少转换与写盘开销；退出前会等待待处理数据保存完成

### 平台体验

| 能力 | Android | Windows | Linux |
| --- | :---: | :---: | :---: |
| 在线搜索、播放与下载 | 支持 | 支持 | 支持 |
| 本地曲库、应用内歌词 | 支持 | 支持 | 支持 |
| 系统媒体控制 | 通知栏、锁屏 | 应用内 | 应用内 |
| 蓝牙断开或切换自动暂停 | 支持 | 支持 | 暂不支持 |
| 桌面歌词 | 系统悬浮窗 | 置顶独立窗口 | 暂不支持 |
| 下载目录设置 | 手动输入路径 | 文件夹选择器 | 原生文件夹选择器 |
| 后台运行 | 系统媒体通知 | 关闭后最小化到托盘 | 最小化可播放，关闭即退出 |

Linux 支持调用默认应用打开歌曲、所在目录和网页。退出前会等待待处理的数据保存；暂不提供托盘、窗口尺寸记忆及桌面悬浮歌词。Linux 删除歌曲文件为永久删除。

### 诊断与日志

- 设置页可打开“诊断与日志”，查看网络来源失败、Apple/MusicBrainz 回退、断点续传、数据备份恢复和未捕获异常
- 日志在内存中保留最近 500 条，并写入最大约 1 MB 的滚动日志文件
- 可一键复制诊断信息；写入和复制前会移除 URL 查询参数及片段，避免携带临时签名
- 可单独清空日志，不会删除歌曲、设置、歌单或下载任务

开启代理后若浏览器能搜索歌曲宝、青听却提示拒绝访问，可先检查代理设置；TUN 接管网络后出现此问题的情况在 Linux 和 Windows 上均有反馈。当前 Dart HTTP 客户端读取进程中的 `http_proxy` / `https_proxy` / `no_proxy`（也支持大写），不自动同步浏览器的代理扩展、桌面代理规则或验证 Cookie；从终端与应用菜单启动也可能继承不同的环境。HTTP 403 只说明请求被拒绝，不能单凭这个状态确定是代理出口还是网站对程序请求的限制。

排查时先完全退出青听，暂时关闭代理（包括 TUN），再重新启动搜索。若此时正常，应检查代理分流，让歌曲宝使用能正常访问的出口。若仍失败，可在“诊断与日志”复制对应的来源错误。从 1.5 起，青听不再因来源请求失败而设置本地冷却或倒计时；调整网络后可直接重试，实际是否允许访问仍由网站决定。

使用 Clash / Mihomo 规则模式时，可尝试把 `- DOMAIN-SUFFIX,gequbao.com,DIRECT` 加在现有 `rules` 列表的前面，然后开启 TUN 验证，并在代理连接日志中确认歌曲宝命中直连。规则按从上到下的顺序匹配，参见 [Mihomo 路由规则文档](https://wiki.metacubex.one/config/rules/)。该规则针对歌曲宝域名；音频链接若使用其他域名，需根据实际连接单独检查。

## 使用说明

1. 在“搜索”页选择音乐来源，输入歌名或歌手；点击来源按钮可在“歌曲宝”和“MY FREE MP3”之间一键切换。
2. 选择搜索结果即可在线播放或加入下载队列；MY FREE MP3 首次播放时需要短暂生成可播放的 MP3，界面会显示准备状态。
3. 下载完成的歌曲会出现在“本地”页；旧文件可在“设置”中扫描导入。
4. 点击底部播放栏可进入歌词页，播放队列按钮用于查看和调整后续歌曲。
5. 桌面歌词、默认启动页面、启动自动播放、下载目录和并发数均可在“设置”中调整。

Android 可能根据功能请求以下权限：

- 通知权限：显示播放控制通知，适用于 Android 13 及以上版本。
- 悬浮窗权限：在其他应用上方显示歌词，仅在启用悬浮歌词时需要。
- 文件访问权限：扫描或写入用户选择的公共存储目录。

## 开发环境

开始前请安装：

- Flutter SDK，所带 Dart SDK 需满足 `^3.12.2`
- Android Studio 与 Android SDK，用于 Android 开发
- Visual Studio 2022 的“使用 C++ 的桌面开发”工作负载，用于 Windows 开发
- JDK 17 或更高版本，用于 Android 构建

克隆项目后安装依赖：

```powershell
git clone https://github.com/sadpotato1006/music_downloader.git
cd music_downloader
flutter pub get
```

运行应用：

```powershell
# Windows
flutter run -d windows

# 已连接的 Android 设备或模拟器
flutter run -d <device-id>
```

仓库在部分开发环境中也可能包含本地 Flutter 工具链。使用它时，可将上述 `flutter` 替换为：

```powershell
.\.tooling\flutter\bin\flutter.bat
```

`.tooling`、`.pub-cache`、`.gradle` 和 `.appdata` 均为本地目录，不会提交到 Git。

## 检查与测试

仓库中的源码、脚本和文档统一使用 UTF-8 编码；编辑器建议启用 `.editorconfig` 支持，避免中文提示被错误转码。

```powershell
flutter analyze
flutter test
```

主要测试覆盖歌曲来源解析、在线歌词匹配、ID3 歌词读写、Apple/MusicBrainz 专辑元数据匹配、原子存储恢复、并发下载路径预留、断点续传、超大封面中止、诊断日志脱敏和本地曲库搜索；另有选歌及“下一首播放”竞态、后台歌词失败及过期结果、同名歌曲封面隔离、大曲库补全访问次数和歌词页局部刷新回归测试。下载入库测试覆盖封面缓存失败、曲库保存失败后的单独重试和重启恢复；歌词搜索测试覆盖并发上限、分批刷新、关键词切换、缓存淘汰和编辑期间的过期读取。

可用 `dart run tools/benchmark_json_saves.dart` 对比密集保存请求的序列化次数、JSON 体积和转换耗时。该基准使用合成曲库，不访问个人数据，也不包含磁盘写入耗时。

## Linux 构建与安装

需要在 Linux 主机内构建；Windows 可以使用 WSL Ubuntu，不能直接用 Windows Flutter SDK 交叉编译。建议先以 **Ubuntu 24.04 x86_64** 为目标。使用 Flutter **3.44.2 / Dart 3.12.2**，或满足 `pubspec.yaml` 的兼容版本。

Ubuntu 24.04 构建依赖：

```bash
sudo apt-get update
sudo apt-get install -y clang cmake ninja-build pkg-config libgtk-3-dev \
  libstdc++-12-dev libmpv-dev libmimalloc-dev liblzma-dev dpkg-dev xdg-user-dirs fonts-noto-cjk
flutter config --enable-linux-desktop
flutter doctor -v
flutter pub get --enforce-lockfile
flutter analyze
flutter test
flutter run -d linux
```

项目已包含 Linux 工程，无需再次运行 `flutter create`。播放器在 Linux 上使用系统 `libmpv` 和动态链接的 `mimalloc`。

生成 Release 便携包及 Debian/Ubuntu 安装包：

```bash
bash tools/linux/build-linux.sh --deb
```

仅生成便携包时省略 `--deb`。Flutter 不在 PATH 时可设置 `FLUTTER_BIN=/path/to/flutter/bin/flutter`。输出位于 `dist/`，名称如 `QingTing-v1.5.0+32-linux-x64.tar.gz` 和同名 `.deb`；原始可运行目录位于 `build/linux/x64/release/bundle/`。

安装并启动：

```bash
sudo apt install ./dist/QingTing-v1.5.0+32-linux-x64.deb
qingting
```

安装包自动声明系统库依赖，并添加应用菜单图标。便携包需要保留 `qingting`、`lib/`、`data/` 的相对位置，安装包内 README 所列运行库后执行 `./qingting`。运行需要图形桌面和音频设备。

构建产物受构建机的 glibc 等系统库版本约束；Ubuntu 24.04 构建的包不保证能在较旧发行版运行。安装包通过 `dpkg-shlibdeps` 推导依赖，额外声明动态加载的 `libmpv2`。ARM64 需要在对应架构的 Linux 主机及 Flutter 工具链上构建，尚需单独验证。

WSL 开发时建议在 Linux 文件系统中的独立源码副本构建，避免与 Windows 共用 `.dart_tool`、`build` 和 Flutter SDK 缓存。配置、曲库等使用 XDG 用户数据目录，默认下载到用户下载目录下的 `QingTing` 文件夹。

仓库还提供手动触发的 GitHub Actions 工作流 **Build Linux**，在 Ubuntu 24.04 上分析、测试和构建，生成的 `.deb` 与 `.tar.gz` 可在工作流产物中下载。

### Arch Linux x86_64

使用专门在 Arch 环境中编译的 `.pkg.tar.zst` 包。先完整更新系统，再安装：

```bash
sudo pacman -Syu
sudo pacman -U ./qingting-1.5.0+32-1-x86_64.pkg.tar.zst
qingting
```

pacman 会处理 GTK 3、mpv、mimalloc 等依赖。需要中文字体时可安装 `noto-fonts-cjk`。安装包包含应用菜单图标，支持用 `sudo pacman -R qingting` 卸载；用户曲库和设置保留在 XDG 用户数据目录。

从当前源码构建（在 Arch 中以普通用户运行）：

```bash
sudo pacman -Syu --needed base-devel clang cmake ninja pkgconf gtk3 mpv \
  mimalloc xdg-user-dirs git curl unzip xz
# 安装 Linux Flutter 3.44.2 / Dart 3.12.2，并将 flutter 加入 PATH
flutter config --enable-linux-desktop
bash tools/arch/build-arch.sh
```

脚本读取 `pubspec.yaml` 的版本号，使用锁定依赖编译，然后生成带 SHA-256 校验的本地 PKGBUILD 并调用 `makepkg`。输出在 `dist/`，同时生成安装包的 `.sha256` 文件。可用 `FLUTTER_BIN=/path/to/flutter/bin/flutter` 指定 SDK。`makepkg` 必须由普通用户执行，脚本不会自动安装软件或修改系统依赖。

Arch 与 Ubuntu 的系统库版本可能不同（例如 mimalloc 的 ABI 主版本），因此不要将 Ubuntu 便携包直接重打包后用于 Arch。Arch 脚本会记录当前链接的 mimalloc ABI，并在安装包中约束对应版本；将来系统库发生 ABI 升级时应重新构建。Arch 和 Ubuntu 构建也应使用各自的源码副本及构建缓存。

手动触发的 GitHub Actions 工作流 **Build Arch Linux** 使用官方 Arch 容器构建，产物包含 `.pkg.tar.zst` 安装包及校验文件。该流程不会发布到 AUR。

## Android 构建

调试 APK：

```powershell
flutter build apk --debug
```

Release 构建必须在项目根目录创建未纳入版本控制的 `keystore.properties`：

```properties
storeFile=C:\path\to\release.jks
storePassword=your-store-password
keyAlias=your-key-alias
keyPassword=your-key-password
```

然后执行：

```powershell
flutter build apk --release
```

APK 默认输出到 `build\app\outputs\flutter-apk\`，构建后可另存为 `dist\QingTing-v1_5_0.apk`。当前应用 ID 为 `com.pobb.qingtingnew`。

请妥善备份签名文件及密码。后续发布同一应用的更新时，必须继续使用相同签名；不要将 `keystore.properties`、`*.jks` 或其他密钥文件提交到仓库。

## Windows 构建

生成 Release：

```powershell
flutter build windows --release
```

产物位于 `build\windows\x64\runner\Release`。分发时必须保留该目录中的 DLL 和 `data` 文件夹，不能只复制 `qingting.exe`。

生成中文安装程序：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File tools\windows_installer\build-windows-installer.ps1 `
  -Version 1.5.0
```

安装程序输出到 `dist\QingTingSetup-v1_5_0.exe`，默认安装位置为 `%LOCALAPPDATA%\Programs\QingTing`，并创建桌面和开始菜单快捷方式。升级采用临时目录验证和原子替换；含有个人文件且不属于青听的非空目录不会被清理。

## 项目结构

```text
lib/                         Flutter 入口、模型和平台服务
lib/ui/                      搜索下载、曲库、歌词设置、播放和诊断界面
lib/controller/              搜索、下载、曲库、播放和设置控制器分部
test/                        自动化测试
android/                     Android 原生配置与媒体控制
windows/                     Windows Runner、托盘和桌面歌词窗口
tools/windows_installer/     Windows 安装程序源码与构建脚本
assets/                      应用资源
```

## 数据来源与责任边界

- 歌曲搜索与详情来自[歌曲宝](https://www.gequbao.com/)的公开页面，以及 [MY FREE MP3](https://myfreemp3.ink/) 前端公开使用的搜索、试听与下载接口。
- 缺失歌词的在线歌曲会尝试使用 [LRCLIB](https://lrclib.net/) 的公开接口进行匹配；未找到可靠结果时不会写入歌词。
- 缺失的专辑元数据默认来自 [Apple iTunes Search API](https://developer.apple.com/library/archive/documentation/AudioVideo/Conceptual/iTuneSearchAPI/)，无法可靠匹配时再使用 [MusicBrainz](https://musicbrainz.org/) 兜底。
- 页面结构、接口签名规则、资源地址或第三方服务策略变化时，相关功能可能暂时不可用。
- 项目不会尝试绕过登录、付费、验证码、访问频率限制或版权保护措施。
- 音乐资源的版权归原作者及权利人所有。如有侵权，请联系内容提供方或项目维护者处理。

完整版本记录见 [CHANGELOG.md](CHANGELOG.md)。问题反馈请前往 [GitHub Issues](https://github.com/sadpotato1006/music_downloader/issues)。
