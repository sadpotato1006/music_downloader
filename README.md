# 青听

<p align="center">
  <img src="assets/logo.jpg" alt="青听 Logo" width="120">
</p>

青听是一款使用 Flutter 开发的个人音乐工具，支持在 Android 和 Windows 上搜索、播放、下载及管理音乐。

当前版本：`v1.2.5+15`

> 本项目仅解析公开可访问的网页内容，不处理登录、付费、验证码、DRM 或其他访问限制。

## 功能

### 搜索与下载

- 搜索歌曲并查看历史搜索记录
- 在线播放，或将歌曲加入下载队列
- 显示下载进度，支持暂停、取消和失败重试
- 优先选择 MP3；仅找到其他格式时会先征求确认
- 下载 MP3 后写入歌名、歌手、专辑、歌词和封面等 ID3 信息
- 通过 MusicBrainz 匹配和补全缺失的专辑名称

### 播放与歌词

- 播放、暂停、上一首、下一首、单曲循环和随机队列
- 查看、调整和持久化播放队列
- 完整歌词页支持同步滚动、点击跳转和拖动播放进度
- Android 支持通知栏与锁屏媒体控制
- Windows 支持置顶桌面歌词、自由拖动和鼠标穿透锁定；锁定后悬浮歌词可通过开锁图标一键解锁
- Windows 会记住主窗口上次的正常尺寸，下次启动时自动恢复
- Android 支持系统悬浮歌词，需要授予悬浮窗权限

### 本地音乐

- 扫描下载目录，将已有歌曲导入本地曲库
- 按歌名、歌手、专辑、歌词、拼音或拼音首字母搜索
- 编辑本地歌曲的歌名、歌手、专辑、歌词和封面
- 通过歌曲的“更多”菜单收藏或取消收藏，创建自定义歌单并查看最近播放
- 打开歌曲文件或所在目录
- 批量补全缺失的专辑名称

### 平台体验

| 能力 | Android | Windows |
| --- | :---: | :---: |
| 在线搜索、播放与下载 | 支持 | 支持 |
| 本地曲库 | 支持 | 支持 |
| 系统媒体控制 | 通知栏、锁屏 | 应用内 |
| 桌面歌词 | 系统悬浮窗 | 置顶独立窗口 |
| 下载目录设置 | 手动输入路径 | 文件夹选择器 |
| 后台运行 | 系统媒体通知 | 关闭后最小化到托盘 |

## 使用说明

1. 在“搜索”页输入歌名或歌手，选择歌曲即可播放或下载。
2. 下载完成的歌曲会出现在“本地”页；旧文件可在“设置”中扫描导入。
3. 点击底部播放栏可进入歌词页，播放队列按钮用于查看和调整后续歌曲。
4. 桌面歌词、默认启动页面、启动自动播放、下载目录和并发数均可在“设置”中调整。

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

主要测试覆盖歌曲来源解析、ID3 歌词读写、专辑元数据匹配和本地曲库搜索。

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

APK 输出到 `build\app\outputs\flutter-apk\`。当前应用 ID 为 `com.pobb.qingtingnew`。

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
  -Version 1.2.5
```

安装程序输出到 `dist\QingTingSetup-v1_2_5.exe`，默认安装位置为 `%LOCALAPPDATA%\Programs\QingTing`，并创建桌面和开始菜单快捷方式。

## 项目结构

```text
lib/                         Flutter 界面、业务逻辑和平台服务
test/                        自动化测试
android/                     Android 原生配置与媒体控制
windows/                     Windows Runner、托盘和桌面歌词窗口
tools/windows_installer/     Windows 安装程序源码与构建脚本
assets/                      应用资源
```

## 数据来源与责任边界

- 歌曲搜索与详情来自[歌曲宝](https://www.gequbao.com/)的公开页面。
- 专辑元数据来自 [MusicBrainz](https://musicbrainz.org/) 的公开接口。
- 页面结构、资源地址或第三方服务策略变化时，相关功能可能暂时不可用。
- 项目不会尝试绕过登录、付费、验证码、访问频率限制或版权保护措施。
- 音乐资源的版权归原作者及权利人所有。如有侵权，请联系内容提供方或项目维护者处理。

完整版本记录见 [CHANGELOG.md](CHANGELOG.md)。问题反馈请前往 [GitHub Issues](https://github.com/sadpotato1006/music_downloader/issues)。
