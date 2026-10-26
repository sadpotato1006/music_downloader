<p align="center">
  <img src="assets/logo.jpg" alt="青听" width="112">
</p>

<h1 align="center">青听</h1>

<p align="center">搜索、聆听与整理你的音乐。<br>v1.7.0 · Android · Windows · Linux</p>

<p align="center">
  <a href="https://github.com/sadpotato1006/music_downloader/releases">下载</a> ·
  <a href="docs/USAGE.md">使用指南</a> ·
  <a href="docs/DEVELOPMENT.md">开发文档</a> ·
  <a href="https://github.com/sadpotato1006/music_downloader/issues">问题反馈</a>
</p>

## 功能

- **搜索与下载**：支持歌曲宝、MY FREE MP3、下歌宝，在线播放、下载队列、暂停和断点续传；下载校验音频内容，链接失效时尝试重新解析。
- **播放与歌词**：播放队列、随机与单曲循环、滚动歌词、点击歌词跳转。
- **本地曲库**：扫描导入，按歌名、歌手、专辑、歌词或拼音搜索，编辑歌曲信息。
- **收藏与歌单**：多选歌曲，批量收藏、加入歌单和修改专辑；歌单文件支持导入、导出与合并。
- **专辑与封面**：自动补全专辑信息，为 MP3 写入歌曲信息、歌词和封面。
- **北科云盘同步**：在设备间同步歌曲及歌曲信息，仅限 USTBer 使用。

## 下载安装

在 [Releases](https://github.com/sadpotato1006/music_downloader/releases) 中选择对应平台的安装包。

| 平台 | 安装方式 | 平台功能 |
| --- | --- | --- |
| Android | APK | 通知栏与锁屏控制、悬浮歌词 |
| Windows | EXE 安装程序 | 托盘后台运行、桌面歌词 |
| Linux | DEB、Arch 安装包或便携包 | 托盘、MPRIS 媒体控制 |

Linux 的依赖和安装说明见[使用指南](docs/USAGE.md#linux-安装与桌面功能)。

## 开始使用

1. 在“搜索”页选择音乐来源，搜索后播放或下载歌曲。
2. 在“本地”页管理收藏和歌单；已有音乐可在设置中扫描导入。
3. 点击底部播放栏查看歌词；播放、下载与云盘同步选项均在设置中。

歌单通过 `.qingting.json` 文件备份和迁移，不包含音频；缺失歌曲会保留，后续入库时自动尝试匹配。

## 本地开发

使用 Flutter 3.44.2 / Dart 3.12.2，安装依赖后运行：

```bash
flutter pub get
flutter run -d windows
```

Android、Linux 的运行方式、测试和打包步骤见[开发文档](docs/DEVELOPMENT.md)。

## 说明

在线音乐依赖第三方公开来源，服务变化可能影响可用性。下歌宝只解析页面公开的直接音频；浏览器验证或仅提供网盘分享的页面会显示提示。音乐版权归原作者及权利人所有，请在授权范围内使用。

版本记录见 [CHANGELOG](CHANGELOG.md)。
