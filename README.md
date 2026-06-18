# 青听

青听是一个个人使用的 Flutter 音乐搜索、播放、下载工具，目标平台为 Android 和 Windows。

当前版本：`v1.1.5+7`

## 功能概览

- 歌曲宝公开页面搜索与详情解析。
- 在线播放、整卡点击播放、下一首播放、随机播放，以及歌词页进度拖动。
- 播放队列：查看队列、整卡点击跳转播放、下一首播放、移除、清空，并在下次启动时恢复。
- 下载队列：进度显示、暂停、取消、失败重试。
- 优先下载 MP3；只有非 MP3 时会提示确认。
- MP3 下载后写入歌曲信息、专辑、歌词和封面到 ID3 标签。
- 本地音乐页：搜索、图标排序、随机播放本地全部歌曲；歌曲卡片显示歌名，以及同一行内的歌手和专辑，宽屏低高度窗口下自动切换多列歌曲列表。
- 设置页可扫描当前下载目录，把更新前已经存在的歌曲导入到本地列表。
- 本地歌曲信息编辑：歌名、歌手、歌词、封面图片路径或网址。
- 点击播放栏当前歌曲可打开完整歌词页，支持进度拖动、点击歌词跳转、上一首/播放/下一首、随机/单曲循环切换和歌曲信息查看。
- 设置页可开启启动软件时自动播放音乐，并可选择启动默认进入搜索页或本地页。
- 下载目录设置：Android 支持手动路径，Windows 支持选择文件夹。
- Windows 版提供绿色版目录和安装脚本模板。

## v1.1 主要变化

这次 v1.1 相比 v1.0 的核心差异：

- 新增请求节流和冷却机制，减少歌曲宝 `HTTP 520/403/429` 拦截概率。
- 搜索结果不再自动请求封面详情，搜索更快、更不容易被拦。
- 错误提示更明确，区分链接过期、拒绝访问、请求太频繁、网络超时等情况。
- 本地音乐支持排序。
- 本地音乐可编辑歌名、歌手、歌词和封面。
- 播放栏可打开完整歌词页，歌词页支持进度拖动和点击歌词跳转。
- 播放队列支持查看、指定播放、移除和清空，队列卡片显示歌手和专辑。
- 新增本地全部歌曲随机播放入口，会生成可预览、可移除的随机播放队列。
- 本地音乐页顶部操作合并为一行，随机播放改名为“点击开始随机播放”并占主要宽度，排序和搜索只保留图标且按钮略微收小；底部播放栏只保留播放/暂停和播放队列。
- 歌曲卡片支持点击任意位置播放并显示按压反馈，取消格式后缀，歌手和专辑同一行显示，封面占比略增、卡片间距进一步压缩，卡片宽度略增。
- 下载、扫描、“下一首播放”等全局提示改为带青听图标的轻量通知，不再使用遮挡底部操作的黑色提示条。
- 恢复本地音乐搜索；播放队列整卡点击即可跳转播放对应歌曲，点击当前歌曲不会从头重播，并移除每行最右侧的拖动手柄。
- 底部播放栏不再显示播放进度条；进度拖动移到完整歌词页。
- 顶部四个导航标签略微变薄并缩小文字，减少顶部占用空间。
- 设置页新增本地歌曲扫描入口、启动自动播放开关和默认启动页面选择；同时下载默认值改为 1，调高时会提示请求过频繁风险；源代码链接最多两行完整换行显示。
- 下载 MP3 时会更完整地解析并写入专辑信息；外部 MP3 支持读取 `USLT`、`SYLT`、歌词类 `TXXX` 内嵌歌词和同名 `.lrc` 旁挂歌词。
- 搜索结果和本地歌曲列表在宽屏低高度窗口下自动切换多列布局，提高信息密度。
- 音量设置会保存，下次打开继续使用。
- Windows 端补齐文件夹选择、浏览器跳转、窗口标题和构建配置。
- Android 版本号更新到 v1.1；当前 release 已切换为新包名和新签名，会作为独立新应用安装。
- Windows 安装器改为中文向导，并明确使用 UTF-8 编译，避免中文标题和按钮乱码。
- 下载页/设置页新增“扫描当前下载目录”，用于导入更新前已经下载到手机或电脑里的歌曲文件。

完整记录见 [CHANGELOG.md](CHANGELOG.md)。

## Git Diff 对比摘要

当前工作区主要改动集中在：

- `lib/app_controller.dart`：请求节流/冷却、错误分类、本地歌曲编辑、本地目录扫描导入、队列管理、音量记忆、启动自动播放、默认启动页面。
- `lib/gequbao_source.dart`：浏览器式请求头、HTTP 520/429 等处理、搜索不再补封面详情、详情页专辑解析。
- `lib/id3_lyrics_embedder.dart`：歌词、封面、标题、歌手、专辑的 ID3 写入和读取，兼容更多歌词帧。
- `lib/main.dart`：顶部导航、轻量通知、本地页搜索和排序、卡片按压反馈、编辑弹窗、完整歌词页控制按钮、播放队列面板、设置页开关。
- `lib/models.dart`：设置项、本地歌曲、搜索详情和播放项字段扩展。
- `lib/storage_service.dart`：本地封面缓存和下载记录管理。
- `test/*`：歌曲宝解析、ID3 写入读取、设置保存测试。
- `windows/*`：Windows 标题、资源信息和构建安装路径。
- `tools/windows_installer/*`：Windows 中文安装器和安装脚本模板。

## 合规边界

青听只解析公开可访问页面。遇到登录、付费、验证码、DRM、403、明确限制或页面结构变化时，应用只提示失败，不做绕过。

资源来源于网络，如有侵权请联系删除。

## 构建前准备

本项目把 Flutter SDK、Pub 缓存和 Gradle 缓存放在工作区内，方便在当前机器上稳定构建。

常用环境变量：

```powershell
$env:GIT_CONFIG_GLOBAL=(Resolve-Path .codex_gitconfig).Path
$env:PUB_CACHE=(Join-Path (Get-Location) '.pub-cache')
$env:APPDATA=(Join-Path (Get-Location) '.appdata\roaming')
$env:LOCALAPPDATA=(Join-Path (Get-Location) '.appdata\local')
$env:GRADLE_USER_HOME=(Join-Path (Get-Location) '.gradle')
$env:DART_SUPPRESS_ANALYTICS='true'
$env:ANDROID_HOME='C:\Users\Pobb\AppData\Local\Android\Sdk'
$env:ANDROID_SDK_ROOT=$env:ANDROID_HOME
$env:JAVA_HOME='C:\Program Files\Eclipse Adoptium\jdk-25.0.2.10-hotspot'
$env:Path="$env:JAVA_HOME\bin;$env:ANDROID_HOME\platform-tools;$env:Path"
```

## 检查与测试

```powershell
.\.tooling\flutter\bin\flutter.bat analyze --no-pub
.\.tooling\flutter\bin\flutter.bat test --no-pub
```

## Android 构建

Release APK：

```powershell
.\.tooling\flutter\bin\flutter.bat build apk --release --no-pub
```

产物：

```text
build\app\outputs\flutter-apk\app-release.apk
```

签名配置：

- release 签名从项目根目录 `keystore.properties` 读取。
- `keystore.properties`、`*.jks`、`*.keystore` 已加入 `.gitignore`，不要上传到 Git/GitHub。
- 当前 release APK 已切换到新的应用身份：`com.pobb.qingtingnew`。
- 当前 release 签名使用新生成的 `qingting-new-release.jks`，它只保存在本地且被 `.gitignore` 忽略。
- 这个 release 会被 Android 当成一个新应用，不会覆盖旧包名 `com.pobb.qingting` 的旧版青听。
- 如果以后继续升级这个“新应用线”，必须保留并继续使用当前这份 `qingting-new-release.jks` 和对应的 `keystore.properties`。

## Windows 构建

Release：

```powershell
.\.tooling\flutter\bin\flutter.bat build windows --release --no-pub
```

产物目录：

```text
build\windows\x64\runner\Release
```

Windows 版不能只复制 `qingting.exe`，必须连同旁边的 DLL 和 `data` 文件夹一起带走。

安装脚本模板：

```text
tools\windows_installer\install-qingting.bat
tools\windows_installer\install-qingting.ps1
```

脚本会把 Windows 版安装到：

```text
%LOCALAPPDATA%\Programs\QingTing
```

并创建桌面和开始菜单快捷方式。

正式中文安装器：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\windows_installer\build-windows-installer.ps1 -Version 1.1
```

产物：

```text
dist\QingTingSetup-v1_1.exe
```

安装器界面为中文，C# 编译使用 `/codepage:65001` 读取 UTF-8 源码；安装后生成的卸载脚本会以带 BOM 的 UTF-8 写入，避免 Windows PowerShell 显示中文时乱码。
