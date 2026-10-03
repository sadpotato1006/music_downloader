青听 Linux 版

便携包：解压后在此目录运行 ./qingting，保留 lib/ 和 data/。
Ubuntu 24.04 运行依赖：
  sudo apt install libgtk-3-0t64 libmpv2 libmimalloc2.0 libstdc++6 libsecret-1-0 libwebkit2gtk-4.1-0 libayatana-appindicator3-1 libpulse-mainloop-glib0 xdg-user-dirs fonts-noto-cjk gnome-keyring
需要桌面图形会话和可用的音频设备。此包不捆绑系统音频库。

deb 安装包：
  sudo apt install ./QingTing-v*-linux-x64.deb
安装后从应用菜单打开“青听”，或执行 qingting。

Arch Linux x86_64 安装包：
  sudo pacman -Syu
  sudo pacman -U ./qingting-*-x86_64.pkg.tar.zst
pacman 会安装 GTK 3、mpv、mimalloc、WebKitGTK 4.1、Ayatana AppIndicator、libpulse、libsecret 等运行依赖。
中文字体可选安装：sudo pacman -S --needed noto-fonts-cjk
Arch 包在 Arch 环境中编译，不要将 Ubuntu 便携包直接转换为 Arch 包。

支持搜索、播放、下载、曲库、应用内歌词、原生目录选择、专辑补全和北科云盘扫码同步。
云盘记住授权需要运行并解锁 Secret Service 密钥环，例如 gnome-keyring。
扫码窗口属于青听，关闭扫码窗口即取消；哈希比较、共享删除记录、原下载顺序和失败重试与其他平台一致。

托盘菜单：打开窗口、播放/暂停、上一首、下一首、退出。
设置 → Linux 桌面：切换关窗后是否继续在托盘运行，或直接退出青听。
KDE 原生支持状态通知托盘；GNOME 需启用 AppIndicator 扩展。
无托盘时关窗退出；托盘消失时恢复主窗口；重复启动会显示已有窗口。
退出会暂停下载，完成已开始的同步歌曲并保存记录，跳过其余同步任务。
自动记住窗口尺寸和最大化状态，支持 X11 / Wayland；不恢复 Wayland 窗口坐标。
窗口及托盘设置保存在 ~/.config/qingting/desktop.ini，或 XDG_CONFIG_HOME 指定的对应目录。

MPRIS 系统媒体控制支持歌曲、封面、进度、播放/暂停、停止、切歌、跳转、音量、随机与循环。
可用 playerctl -p qingting 控制，媒体快捷键由桌面环境转发。
蓝牙断开自动暂停依赖 PulseAudio，或 PipeWire 的 pipewire-pulse 服务。
播放器优先使用 PulseAudio 接口；不可用时可回退到其他后端播放，但回退后无法监听蓝牙切换。
监听青听进程实际使用的输出，其他程序使用的蓝牙设备断开不会误暂停。
Linux 暂不提供桌面悬浮歌词。

从曲库删除歌曲文件会移入系统回收站；回收站不支持该位置时保留文件并提示失败。
同步删除仍按云端删除记录清理匹配副本，使用前阅读同步页面的说明。
文件管理器支持定位歌曲，不支持定位时打开所在目录。
下载目录可在设置中修改。配置和曲库保存在 XDG 用户数据目录。

构建及兼容性说明见项目 README：
https://github.com/sadpotato1006/music_downloader
