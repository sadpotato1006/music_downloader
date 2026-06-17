# 青听

青听是一个个人使用的 Flutter 音乐搜索、播放、下载工具，目标平台为 Android 和 Windows。

当前版本：`v1.1.4+6`

## 功能概览

- 歌曲宝公开页面搜索与详情解析。
- 在线播放、上一首/下一首、随机播放、进度拖动、音量控制、循环模式。
- 播放队列：查看队列、指定播放、下一首播放、拖动排序、移除、清空，并在下次启动时恢复。
- 下载队列：进度显示、暂停、取消、失败重试。
- 优先下载 MP3；只有非 MP3 时会提示确认。
- MP3 下载后写入歌曲信息、歌词和封面到 ID3 标签。
- 本地音乐页：搜索、按下载时间/歌名/歌手排序、播放本地文件；宽屏低高度窗口下自动切换多列歌曲列表。
- 本地音乐可扫描当前下载目录，把更新前已经存在的歌曲导入到本地列表。
- 本地歌曲信息编辑：歌名、歌手、歌词、封面图片路径或网址。
- 播放时显示滚动歌词，点击播放栏可查看完整歌词。
- 下载目录设置：Android 支持手动路径，Windows 支持选择文件夹。
- Windows 版提供绿色版目录和安装脚本模板。

## v1.1 主要变化

这次 v1.1 相比 v1.0 的核心差异：

- 新增请求节流和冷却机制，减少歌曲宝 `HTTP 520/403/429` 拦截概率。
- 搜索结果不再自动请求封面详情，搜索更快、更不容易被拦。
- 错误提示更明确，区分链接过期、拒绝访问、请求太频繁、网络超时等情况。
- 本地音乐支持搜索和排序。
- 本地音乐可编辑歌名、歌手、歌词和封面。
- 播放栏支持歌词滚动显示和完整歌词面板。
- 播放队列支持查看、拖动排序、移除和清空。
- 新增随机顺序播放，播放栏提供独立的随机开关。
- 搜索结果和本地歌曲列表在宽屏低高度窗口下自动切换多列布局，提高信息密度。
- 音量设置会保存，下次打开继续使用。
- Windows 端补齐文件夹选择、浏览器跳转、窗口标题和构建配置。
- Android 版本号更新到 v1.1；当前 release 已切换为新包名和新签名，会作为独立新应用安装。
- Windows 安装器改为中文向导，并明确使用 UTF-8 编译，避免中文标题和按钮乱码。
- 下载页/本地页新增“扫描当前下载目录”，用于导入更新前已经下载到手机或电脑里的歌曲文件。

完整记录见 [CHANGELOG.md](CHANGELOG.md)。

## Git Diff 对比摘要

当前工作区主要改动集中在：

- `lib/app_controller.dart`：请求节流/冷却、错误分类、本地歌曲编辑、本地目录扫描导入、队列管理、音量记忆。
- `lib/gequbao_source.dart`：浏览器式请求头、HTTP 520/429 等处理、搜索不再补封面详情。
- `lib/id3_lyrics_embedder.dart`：歌词、封面、标题、歌手的 ID3 写入和读取。
- `lib/main.dart`：顶部导航、搜索页提示、下载页/本地页目录扫描入口、本地页搜索排序、编辑弹窗、歌词面板、播放队列面板。
- `lib/models.dart`：设置项和播放项字段扩展。
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
