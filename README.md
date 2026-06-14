# 青听

青听是一个个人使用的 Flutter 音乐搜索、播放、下载工具，目标平台为 Windows 和 Android。

## 已实现

- 歌曲宝公开页面搜索与详情解析。
- 在线播放、播放队列、上一首/下一首、进度拖动、音量和循环模式。
- 下载队列、进度、暂停、取消、失败重试。
- 优先 MP3；没有 MP3 时会确认是否下载其他格式。
- 默认下载到系统下载目录下的 `QingTing`，设置页可手动修改下载路径。
- 已下载列表、本地播放、打开文件、打开位置、删除记录。
- 白色与淡绿色为主的简洁界面，桌面侧边导航、手机底部导航。

## 合规边界

应用只解析公开可访问页面。如果歌曲宝返回 403、验证码、登录限制、页面结构变化或没有公开音频链接，应用会提示失败，不做绕过。

## 本机命令

本项目使用工作区内的 Flutter SDK：

```powershell
$env:GIT_CONFIG_GLOBAL=(Resolve-Path .codex_gitconfig).Path
$env:PUB_CACHE=(Join-Path (Get-Location) '.pub-cache')
$env:APPDATA=(Join-Path (Get-Location) '.appdata\roaming')
$env:LOCALAPPDATA=(Join-Path (Get-Location) '.appdata\local')
.\.tooling\flutter\bin\flutter.bat analyze --no-pub
.\.tooling\flutter\bin\flutter.bat test --no-pub
```

Android debug APK：

```powershell
$env:ANDROID_HOME="C:\Users\Pobb\AppData\Local\Android\Sdk"
$env:ANDROID_SDK_ROOT=$env:ANDROID_HOME
$env:JAVA_HOME="C:\Program Files\Eclipse Adoptium\jdk-25.0.2.10-hotspot"
$env:FLUTTER_STORAGE_BASE_URL="https://storage.flutter-io.cn"
.\.tooling\flutter\bin\flutter.bat build apk --debug --no-pub
```

产物：

```text
build\app\outputs\flutter-apk\app-debug.apk
```

Windows 桌面构建需要系统启用 Windows Developer Mode，因为 Flutter 插件桌面构建需要 symlink 支持。启用后可运行：

```powershell
.\.tooling\flutter\bin\flutter.bat build windows --debug --no-pub
```
