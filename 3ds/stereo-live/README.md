# New 3DS LL 裸眼立体影片串流

Mac 实时读取单眼影片，每帧使用 stereo-mac 的 Core ML 深度估计与左右眼投影，再用 VideoToolbox 编成 800 × 240 的 H.264 Baseline。New 3DS LL 的 MVD 硬解码器输出 RGB565，上屏每眼显示 400 × 240。实体滑块控制 Mac 端生成的视差，START 返回 Homebrew Launcher。此模式播放视频画面，暂未接入音轨。

## 运行

在本目录运行以下命令。Mac 依赖 Apple Silicon、Swift 6 和支持 TLS PSK 的 Python 3.13+。掌机端的 devkitPro 镜像与 lan-window 相同。两个设备连入同一可信局域网，在掌机的 Homebrew Launcher 按 Y 进入 Netloader。

```sh
../stereo-mac/prepare.sh
./build-mac.sh
(cd ../lan-window && docker run --rm -v "$PWD:/src" -w /src \
  devkitpro/devkitarm@sha256:116afba8df8453961de2936ffab20dd441edf4d682856c1ec8b0e53d7ed0bbf5 sh build-3ds.sh)
python3 stream.py MAC_LAN_IP HANDHELD_LAN_IP --sender /path/to/3dslink --trace .build/run.jsonl
```

默认循环播放 [Blender Foundation 的《Sintel》预告片（CC BY 3.0）](https://durian.blender.org/sharing/)，也可传入本地 SDR 影片路径 `--movie`。使用新的 trace 文件名。部署沿用 lan-window 的一次性 TLS PSK 和 Netloader 启动参数。需要对照 JPEG 逐帧传输时可加 `--codec jpeg`。

## 播放与测量

默认编码目标为 420 kbps，每 12 帧插入一个 IDR。对于此单参考帧、无 B 帧的 VideoToolbox 码流，发送端在缺失 VUI 时标明零帧重排及单帧解码缓冲。接收端避免把重复的 SPS/PPS 提交给 MVD。掌机在独立线程中按照片源时间戳选择垂直刷新，启动时预留 220 ms。Wi-Fi 或解码时间的波动由有限的画面队列吸收。持续拥塞超过发送端队列上限时，丢弃过时的参考链，从下一关键帧恢复。

```sh
python3 stats.py .build/run.jsonl --frames 1253 --loop 1
```

该命令在下一遍开始后统计一整遍。帧率用上屏左右眼一起交换后的 VBlank 时间计算。掌机会对解码后的双眼像素抽样计算签名，便于发现重复画面。淡入、黑场和静止镜头也可能产生相同签名。总延迟从 Mac 取到源图、开始缩放计时，到 Mac 收到对应显示回执为止，包含转换、编码、传输、解码、播放缓冲、刷新等待及回执返回。它是这段处理到显示的延迟上界；未测屏幕像素实际发光的时刻。

## 真机对照

同一台 New 3DS LL、同一段 24 fps 片源，取各版本完整的第一遍（1,253 帧，含启动）。下表的帧率是上屏换帧率。间隔超过 100 ms 的次数反映刷新节奏，画面内容重复需另外核对。

| 版本 | 上屏帧数 | 平均 fps | 最大换帧间隔 | 间隔超过 100 ms | 开始转换至显示回执，中位 / P95 |
| --- | ---: | ---: | ---: | ---: | ---: |
| JPEG | 655 | 12.56 | 317.56 ms | 210 | 169.70 / 367.04 ms |
| H.264，收到即显示 | 1,253 | 24.06 | 217.28 ms | 48 | 62.82 / 130.34 ms |
| H.264，按时间戳播放 | 1,253 | 24.00 | 50.22 ms | 0 | 417.31 / 463.36 ms |
| H.264，按时间戳播放并修正解码参数 | 1,253 | 24.00 | 50.19 ms | 0 | 430.48 / 468.70 ms |

单独加入定时播放后，抽样像素仍在运动镜头中每 12 帧连续重复约 6 帧。修正后，整片相邻签名相同的帧对从 585 降至 127；片尾最后 33 帧的静止画面也出现在原片中。操作者在上屏确认修正后明显更流畅、可以观看。最终版本 Mac 转换与编码耗时中位数为 15.21 ms，掌机硬解为 4.43 ms。该播放缓冲用于影片，窗口触控路径独立。
