# KKRemote Steam Deck 窗口查看器

在原装 SteamOS 桌面模式下，通过局域网查看 Mac 上的单个真实窗口。查看器使用 KKRemote Host 的 TLS-PSK 信令和 direct-ice WebRTC，默认在窗口目录中按应用名匹配 PopAgent。有多个可见窗口时选择面积最大的窗口。按 Esc 退出。

## Mac Host

打开目标窗口，使它出现在当前桌面。使用支持窗口目录的 KKRemoteLabMac 构建，为 Deck 启动一个独立监听端口。以下命令中的 HOST_BIN 是该构建的可执行文件路径，KEY_FILE 是 Host 能读写的私有配对文件路径。Host 可创建新密钥或复用此监听器已有的密钥。

```bash
"$HOST_BIN" --lab-role host --persistent-host --route direct-ice \
  --port 45994 --key-file "$KEY_FILE" --resolution 1280x720 \
  --fps 60 --mbps 12 --playout realtime --duration 86400
```

此命令按物理窗口采集，监听 24 小时。Host 到期或 Mac 重启后需重新运行。客户端只在收到 Host 确认的选窗媒体会话后显示视频。

## Steam Deck

在 Deck 桌面模式的 Konsole 中，从本目录运行以下命令。需要支持 TLS-PSK 客户端回调的 Python 3.13 或更新版本，以及当前图形会话。

```bash
python3 -m venv ~/.local/share/kkremote/venv
~/.local/share/kkremote/venv/bin/pip install --only-binary=:all: -r requirements.txt
install -m 644 viewer.py ~/.local/share/kkremote/viewer.py
~/.local/share/kkremote/venv/bin/python ~/.local/share/kkremote/viewer.py \
  --host "$MAC_LAN_ADDRESS" --port 45994
```

在隐藏输入提示中填写 Host 配对码。也可通过私有通道将配对文件保存到 Deck，将文件权限设为 0600，再通过 `--key-file` 指定路径。可用 `--application` 指定其他应用名。

## 当前验证范围

SteamOS 3.8.16 桌面模式实测通过窗口目录选择 PopAgent、H.264 解码、SDL 全屏显示和 WebRTC 数据通道回声。视频按比例适配屏幕。当前查看器使用 aiortc / PyAV 软件解码。游戏模式、VA-API 接入、音频、远程输入和端到端延迟仍待验证或实现。
