# T02b：RTP、桥接队列与冻结归因

后续 [T02c 真机复测](接收解码与显示逐帧诊断.md)已用 USB 构建 9 接通解码 / 显示队列，并更新正在运行的 Mac Host；本文以下保留 T02b 当轮的设备状态与证据。

2026-11-13。通信侧实现；iOS 客户端布局、手势和输入交互仍由 iOS 会话负责。

## 记录链路与边界

`FrameTrace` schema 2 接上编码输出、RTP 明文头、固定 UDP 桥接出队 / socket 接受和独立 WebRTC renderer 回调。默认关闭，通过 `--frame-trace-dir` 显式启用；每个引擎独立 epoch。帧事件上限 32,768，RTP 分组上限 4,096，每组序号最多 4,096；覆盖、遗漏和淘汰后回调单列。

- `RTPTrace` 从最终 answer 提取主媒体 / RTX PT 和 absolute-capture-time 扩展 ID，校验 RTP / CSRC / 一字节与二字节扩展边界，区分 padding 标志；不读 SRTP 加密负载，不猜 RTX 原始序号。
- WebRTC 在编码 timestamp 上增加随机起点。诊断模式通过公开 transceiver API 协商 absolute-capture-time，至少三组锚点必须证明一个恒定偏移；允许 SDK 两次整数时钟转换产生恒定 −1 / 0 / +1 ms 校准，要求候选唯一且保留时间范围内没有未匹配锚点。否则为 unknown，不采用事件时间邻近匹配。
- `encodedToFirstBridgePacketMs` 包含 SDK packetizer、pacer 和本地 UDP 调度，**没有直接插桩预编译 SDK 的 pacer enqueue**。`encodedToLastOSAcceptedMs` 到最后一个被 OS 接受的已观察数据报；遇到丢包不代表整帧成功发送，也不是物理出网时间。
- 桥接记录每帧首末包、包号、marker、入队 / 出队、队列等待与深度、fragment 完成结果，以及模拟丢包、超期、溢出、socket / Network 错误和停止时取消。聚合到帧，不逐包写盘。
- 接收端以自己的时钟记录包到达及 renderer 回调。仅单主媒体 SSRC 时关联 renderer；跨设备只比较各自局部间隔。随机 `clockDomain` 相同的进程内回环才允许编码输出到 renderer 的时间差。renderer 回调不等于屏幕显示。
- RTX 头可见但 OSN 加密；“原始主媒体包缺失而帧仍回调”是恢复证据，不能把所有 RTX / padding 分组当成重传修复数量。
- 退出流程先停止桥接并记录队列取消，再导出；CLI 运行主线程直到所有已开始的 trace 关闭完成，避免 `exit()` 丢失诊断尾部。

原始 trace 只留在本机沙盒与 `.build/remote-bench/`，不含视频载荷、窗口标题、配对码、地址或原始 SDP。公开汇总见 [JSON](data/2026-11-13-rtp-bridge-trace.json)。有界缓存发生覆盖时，只能解释保留的共同时间范围。

## 编码前筛帧的原因

新增 `--sdk-drop-diagnostics`，只保留固定白名单原因，不保存 SDK 原始日志。日志没有可信的逐帧身份，因此只能与帧记录做区间计数对照，不能把某条 SDK 日志硬绑到某个源帧。

1440p、60 fps、20 Mbps 的原始 H.264 噪声自检中，正常策略记录 920 次 `media_optimization`，编码器输入 / 输出各 277 帧。仅在本机 self-test 以 `--disable-frame-dropper` 做因果对照后，输入 / 输出升到 1,187 帧；稳态平均约 59.1 fps，但实际平均约 **136 Mbps**。原生编码器对这种噪声不能满足 20 Mbps 目标，WebRTC 的 FrameDropper 正在压制超额流量。

因此保留生产限流、拥塞控制和筛帧。`qualityLimitationReason=none` 不代表没有媒体优化筛帧。该禁用参数不允许远端信令开启，也不允许普通 host CLI 使用。

真实窗口超出 60 fps 的捕获回调中，没有进入编码器的包装对象仍记 unknown；它们不能与噪声的明确 SDK 筛帧计数混为一谈。静态 / idle 捕获也不计作网络丢帧。

## 关键帧突发与队列定位

真实 Chrome 窗口显示 2× 运动的密集 SVG 图纸，目标捕获 / 编码 2560×1440，60 fps，20 Mbps 上限。源窗口为 1681×1084 点、2× 像素密度，捕获保持比例后适配到目标；并非原生 16:9 满幅素材。图纸是 SDR 内容，主机 HEVC 回环经过 10 位 PQ 捕获和编码；这不替代真实 HDR 母版的色彩验收。

2 秒周期关键帧下，35 秒本机回环约 59.9 fps、实际约 13.0 Mbps。逐帧证据定位到一张 **286,645 字节关键帧**：247 个主媒体 RTP 包分布在 **70.54 ms** 内；对应 renderer 间隔 **93.33 ms**。编码输出前后只隔 **20.07 ms**，桥接队列等待极短。瓶颈是大帧分包与发送节奏，不能归咎于 Ponte 桥接积压。

该轮编码输出到最后一次 OS 接受 P95 为 **3.16 ms**；每帧桥接最大等待的 P95 为 **0.00396 ms**。P95 很低仍可能掩盖每两秒一次的大关键帧尖峰，因此分析器另列 key / delta 大小和长帧间隔。

`--hevc-keyframe-seconds 2|10` 用于周期关键帧对照，控制的是最多相隔多少帧，不改变按需 ForceKeyFrame、NACK / RTX / PLI。新代码默认 **10 秒 × 初始化帧率**，60 fps 时为 600 帧；CLI 可指定 2 回到旧策略。帧率低于目标时实际墙钟间隔可更长，不能把它解释为严格的 10 秒定时器。编码汇总增加 `maximumKeyframeIntervalFrames` 以验证配置实际应用。

| 35 秒同素材 HEVC 回环 | 周期 2 秒 | 周期 10 秒 |
|---|---:|---:|
| 稳态平均接收 fps | 59.94 | 59.97 |
| 稳态实际视频 Mbps | 13.01 | 13.32 |
| 关键帧数 | 18 | 4 |
| renderer 间隔 >50 ms 次数 | 17 | 3 |
| renderer 间隔 P95 / max | 25.40 / 93.33 ms | 24.09 / 80.95 ms |
| SDK 冻结 | 0 | 0 |

这减少了周期突发的次数，没有消除单张关键帧的发包时间。新策略仍有约 81 ms 的尖峰；尚未单独验证所有素材的图像质量和异地手机恢复。不会将这轮短测写成最终稳定性验收。

## 丢包恢复的证据

原有 `--simulate-loss` 包含两个阶段：第 5–15 秒每 100 个 RTP 包丢一个；第 15 秒开始完全丢弃 RTP 200 ms。后者本身就会产生一次冻结，不能用“冻结计数必须为零”验收这种注入。

35 秒真实窗口回环记录 403 个模拟丢弃，接收端原始主媒体序号缺失恰好 403 个；OS 已接受但接收未见的主媒体序号为 0。最大 renderer 间隔 **223.84 ms**，最后一个被注入丢弃的包到下一次 renderer 回调 **27.66 ms**。这是观察到的包边界间隔，不是精确的断流结束到修复耗时；本轮未出现持续数秒的恢复尾巴。

新增 `--simulate-outage-ms 1200` 仅允许和 `--self-test --simulate-loss` 一起使用，用更长断流检查关键帧请求 / 恢复。真实远端不注入这些丢包。

| 受控断流 | 周期 | 最大 renderer 间隔 | 最后注入丢包→下一回调 | PLI |
|---|---:|---:|---:|---:|
| 200 ms（35 秒旧策略轮） | 2 秒 | 223.84 ms | 27.66 ms | 0 |
| 200 ms（25 秒新策略轮） | 10 秒 | 218.72 ms | 39.55 ms | 0 |
| 1,200 ms（25 秒） | 2 秒 | 1,599.73 ms | 398.92 ms | 0 |
| 1,200 ms（25 秒） | 10 秒 | 1,315.92 ms | 116.60 ms | 1 |

10 秒周期的长断流轮触发 PLI，并在下个周期之前产生恢复关键帧。所有注入轮的 SDK 冻结计数都是 1；长断流轮含约 1.2 秒人为断流，所以全段均值约 57 fps，不能拿它宣称持续 60 fps。两种周期各一次的恢复差也不足以证明普遍提速，只证明本次未被周期长度卡住。

观测开销：2 秒周期的 35 秒 trace-off / trace + SDK 原因日志对照，进程 CPU 时间分别约 6.49 / 8.40 秒，平均 fps 60.00 / 59.94。CPU 多约 1.91 秒（含导出，约一个核心的 5.5%），并非零开销；默认关闭逐帧记录和 SDK verbose 回调，后者只用于短时归因。

## 重现与验证

15mac 作为另一台实体接收端，LAN 地址和 `.sgponte` 地址各跑 60 秒，固定 UDP v2 / socket，20 Mbps 上限。15mac 本轮协商 **H.264 SDR**；主机请求 HDR 不会强行把不支持的接收端当成 Main10 客户端。

| 15mac 路径 | 平均接收 fps | 实际视频 Mbps | RTP 丢包 / SDK 冻结 | 编码输出→末包 OS 接受 P95 | 每帧桥接最大等待 P95 |
|---|---:|---:|---|---:|---:|
| LAN | 59.86 | 17.18 | 0 / 0 | 2.38 ms | 0.00446 ms |
| Ponte 地址 | 59.93 | 17.36 | 0 / 0 | 2.10 ms | 0.00425 ms |

两轮都验证了 60 个 capture 锚点；在共同保留区间，OS 已接受的主媒体序号没有接收缺口，桥接无超期 / 溢出 / 发送错误。接收 renderer 间隔 P95 分别 23.87 / 24.48 ms，最大 107.89 / 105.38 ms。仍有短尖峰，不能把“零 SDK 冻结”写成每一帧严格 16.67 ms。

两端位于同一 LAN，Ponte 外层采用的通道未知；这不是异地蜂窝验证。两轮的均值差不能证明 Ponte 比 LAN 更快。远端主机退出码 1 来自 viewer 按计划退出后持续视频 / 控制回声条件失效；viewer 通过，报告与两端 trace 完整。两轮各自验证两端二进制相同；中间新增 CLI 关键帧 / 长断流诊断参数，默认媒体参数仍为旧值。

独立构建 Mac Release，不覆盖正在服务手机的 Host。配对码、Ponte 地址和现有手机端口不变；远端基准默认独立使用 56090 / 56091，测试临时密钥只经已有 SSH 传输，结束清理。

```bash
bash scripts/test-rtp-trace.sh
bash scripts/test-frame-trace.sh .build/TransportTraceB/Build/Products/Release
python3 scripts/analyze-rtp-trace.py <sender.json> --receiver <receiver.json> --output <analysis.json>
```

真实窗口 self-test 在已有 CLI 参数上加 `--frame-trace-dir <沙盒目录> --sdk-drop-diagnostics --hevc-keyframe-seconds 2`；对照组改为 10。每轮单独进程、单独目录。不要并发编译或运行其他基准。

`scripts/benchmark-remote.py` 支持独立 `--sender-app`、`--window-id`、`--hdr`、`--frame-trace` 和 `--sdk-drop-diagnostics`；校验两端可执行文件 SHA-256 相同，并回收两端 trace。网络标签由操作者指定，不声称观察到了 Ponte 外层的直连或中继路径。

最终验证：

- RTP 一 / 二字节扩展、截断 / 非法扩展、主媒体与 RTX / padding 区分、序号与 timestamp 回绕、fragment 完成与丢弃、有界淘汰测试通过；分析器覆盖偏移冲突、锚点不足和跨设备禁止直接时间相减。
- 帧事件并发环形缓存、弱引用身份、编码器错误 / 未匹配、退出等待计数、既有媒体加密与桥接集成检查通过。
- Main10 硬件编解码探针和 HDR renderer / HEVC NAL 检查通过；Mac Release 与 iOS 通用设备 Release 编译通过。iOS 仅编译，未安装或分发。
- 新默认值最终另跑 25 秒真实窗口：接收平均 **59.95 fps**，实际 **13.34 Mbps**，丢包 / SDK 冻结 0 / 0；编码报告确认周期上限 **600 帧**，3 张关键帧，2 次 renderer 间隔 >50 ms，两端 trace 完整导出，缓存没有覆盖。
- CLI 拒绝在普通 host 关闭 FrameDropper、脱离 self-test 注入长断流、非法关键帧参数和缺少 trace 目录的 SDK 原因探针。

性能样本排除了后台停画的 WebKit fixture 和没有输出捕获帧的隐藏自动化窗口；有些早期轮因 CLI 退出过早缺少 trace，仅保留在本机，不作为逐帧证据。最终使用可捕获的真实 Chrome 页面，测试前后都确认素材计数持续增长；临时标签页已关闭。已有手机 Host 进程仍运行旧二进制，连接参数保持原值。本轮优化在新代码和独立测试包生效，尚未替换手机正在使用的 Host。

## 尚未覆盖

预编译 WebRTC pacer 内部 enqueue / dequeue、VT 解码输入 / 回调、应用最终显示队列与屏幕呈现仍未贯通。T02c / T06 保持待验收；当前数据不能声称物理端到端延迟，也不能代替 iPhone 蜂窝网络长测。

## 实现依据

- 固定的 WebRTC M157 源码：`video_stream_encoder.cc` 的 `Drop Frame: target bitrate` 分支及 `WebRTC-FrameDropper`；`rtp_video_sender.cc` 增加发送起始 timestamp；`rtp_sender_video.cc` 生成 absolute-capture-time。仓库本地引用固定在 commit `95554e4a0c5c343fdc989387d9d0ce18e2a2294b`。
- [Apple 关键帧间隔属性](https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_maxkeyframeinterval) 和 [按帧请求关键帧](https://developer.apple.com/documentation/videotoolbox/kvtencodeframeoptionkey_forcekeyframe) 分别控制周期上限和当前帧请求；不能把周期变长等同于禁用恢复关键帧。
- [RTP 规范](https://www.rfc-editor.org/rfc/rfc3550.html) 定义固定头、序号、timestamp 与 SSRC；这些字段不足以解读 SRTP 中加密的媒体负载。
