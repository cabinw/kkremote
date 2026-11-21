# New 3DS LL 局域网窗口与触控板

Mac 通过 ScreenCaptureKit 捕获一个选定的物理窗口，按原比例缩至 400 × 240 以内，用 JPEG 独立帧传到上屏。掌机在上屏叠加黄色指针，下屏作为相对触控板。手指抬起再滑动时指针从上次位置继续。轻点或按 A 单击，B 右键，十字键上下滚动，START 退出。点按和滚轮通过既有 HostWindowControl 回到 Mac 上选定的窗口。指针预览在掌机本地绘制。

## 构建

在本目录运行。Mac 端使用 macOS 15 或更高版本、Xcode 及支持 TLS-PSK 的 Python 3.13+（本机使用 Homebrew Python）。掌机使用上一阶段相同的 devkitPro 镜像：

```sh
./build-mac.sh
docker run --rm -v "$PWD:/src" -w /src \
  devkitpro/devkitarm@sha256:116afba8df8453961de2936ffab20dd441edf4d682856c1ec8b0e53d7ed0bbf5 sh build-3ds.sh
```

## 选择一个窗口并无线部署

Mac 需要录屏与辅助功能权限。可以用 `.build/capture --list` 查看当前可见窗口及编号，也可以运行 `.build/fixture` 打开本实验的原生时钟和按钮窗口，它向终端输出自己的窗口编号。收起或移动窗口可能导致输入校验暂停，重新选择当前可见窗口即可。关闭窗口后应结束会话。

Mac 和掌机连到同一可信局域网，在 Homebrew Launcher 按 Y，再从 Mac 执行下面的命令。把三个大写参数分别替换成 Mac 局域网 IP、掌机显示的 IP 和窗口编号，将 --sender 指向本机的 3dslink 可执行文件。进程在前台运行，Ctrl+C 结束。更换窗口时退出掌机客户端并重新部署。

```sh
python3 relay.py MAC_LAN_IP HANDHELD_LAN_IP WINDOW_ID --sender /path/to/3dslink
```

部署器为每次启动随机生成 256 位会话密钥，绑定指定 Mac 网卡，仅接收指定掌机的连接。密钥通过 Homebrew Launcher 的常规 Netloader 启动参数传递，该部署步骤依赖可信局域网。运行时图像和输入走 TLS 1.2 PSK / AES-128-GCM；已有 KKRemote 配对信息、Host 服务、虚拟显示器和窗口布局均不参与这个独立实验。

采集队列只保留最新图像。掌机网络线程每次发一条请求并接收一幅图像，避免旧帧积压；刷新速率取决于 Wi-Fi、窗口画面和掌机解码速度。下屏 Frames 是累计收到的图像数，静止窗口可重复显示同一捕获帧。上屏时钟和真实按钮计数适合确认内容更新与输入回传。Mac 日志的 TLS_CONNECTED 表示已通过认证，PEER_DISPLAYED_FRAME 表示掌机报告已显示图像，INPUT click OK 表示目标窗口的点击已投递。

## 真机验证（2026-11-21）

在 Mac 端先用回环连接验证了真实窗口 JPEG 采集和输入坐标映射：选定窗口的按钮收到一次点击，计数到 1；错误的 TLS 会话密钥被拒绝。随后将编译好的客户端通过 Netloader 发到 New 3DS LL。局域网会话完成 TLS 认证，掌机回报显示首帧，操作者确认上屏时钟持续走动。Mac 收到四次来自掌机的点击，原生窗口计数由 1 增至 5，操作者在掌机上看到了数字变化。本次验证覆盖窗口采集、上屏显示、下屏指针与回传点击；持续帧率、端到端延迟、右键和滚动手感留待独立测试。
