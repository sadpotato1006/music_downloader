青听 Linux 基础版

便携包：解压后在此目录运行 ./qingting，保留 lib/ 和 data/。
Ubuntu 24.04 运行依赖：
  sudo apt install libgtk-3-0t64 libmpv2 libmimalloc2.0 libstdc++6 xdg-user-dirs fonts-noto-cjk
需要桌面图形会话和可用的音频设备。此包不捆绑系统音频库。

deb 安装包：
  sudo apt install ./QingTing-v*-linux-x64.deb
安装后从应用菜单打开“青听”，或执行 qingting。

Arch Linux x86_64 安装包：
  sudo pacman -Syu
  sudo pacman -U ./qingting-*-x86_64.pkg.tar.zst
pacman 会安装需要的 mpv、GTK 3、mimalloc 等运行依赖。
中文字体可选安装：sudo pacman -S --needed noto-fonts-cjk
Arch 包在 Arch 环境中编译，不要将 Ubuntu 便携包直接转换为 Arch 包。

支持搜索、播放、下载、曲库、应用内歌词和原生目录选择。
Linux 暂不支持桌面悬浮歌词、托盘、蓝牙断开自动暂停和系统媒体控制。
关闭窗口会退出程序；删除歌曲文件会永久删除，操作前会要求确认。
下载目录可在设置中修改。配置和曲库保存在 XDG 用户数据目录。

构建及兼容性说明见项目 README：
https://github.com/sadpotato1006/music_downloader
