# 蜂窝 Ponte 低延迟播放优化

2026-11-13。继续使用 2560×1440 / 60 fps / 20 Mbps 上限、真实浏览器 HDR 窗口、HEVC Main10 PQ、固定 UDP v2、socket 和 interactive pacing。接收设备为 USB 连接的 iPhone 15 Pro Max，USB 用于安装、观察和取报告，媒体连接仍使用已保存的 Ponte 主机名。用户确认蜂窝与 Surge 已开启，测试时手机状态栏显示 5G。应用不能观测 Ponte 外层直连/中继拓扑。

## 蜂窝实测结果

同一台手机、相同内容与连接参数顺序运行。表中时长是手机报告的会话时间，均值/P95 排除首个有效媒体样本后的 10 秒；冻结与 SDK 丢帧是全会话累计。

| 顺序 / 策略 | 时长 | 解码 fps | 接收缓冲均值 / P95 ms | 帧间隔 P95 的区间 P95 ms | 冻结 / SDK 丢帧 |
|---|---:|---:|---:|---:|---:|
| A1 原 adaptive | 777 s | 59.997 | 53.69 / 66.22 | 25.31 | 0 / 0 |
| B1 realtime | 342 s | 60.001 | 1.98 / 5.14 | 35.95 | 0 / 0 |
| A2 原 adaptive 复测 | 258 s | 60.000 | 53.17 / 66.97 | 26.52 | 0 / 0 |
| C1 短缓冲候选，未通过 | 142 s | 59.110 | 13.15 / 16.84 | 27.15 | 3 / 72 |
| B2 最终 realtime 复测 | 351 s | 60.000 | 2.16 / 5.42 | 34.46 | 0 / 0 |

**本轮保留 realtime 作为实验主机的显式配置**：两轮约 5 分 42 秒、5 分 51 秒分别将接收缓冲降至约 2 ms，减少约 51–52 ms 等待。两轮 RTP 丢包、NACK、发送端实际 RTX 与桥接队列丢弃均为 0，原生 1440p / BT.2020 / 10 位 PQ 保持成立。CLI 默认仍为 adaptive，尚未把单设备实验推广为产品全局默认。

低延迟存在可量化取舍：两轮最大渲染回调间隔分别为 **86.65 / 152.10 ms**，旧策略为 **70.53 / 38.42 ms**。低等待使网络帧到达抖动更直接暴露，零 SDK 冻结不等于每帧都按 16.67 ms 呈现。后续应验证有界显示节奏与实际屏幕延迟，不能把更小的接收缓冲解释为所有流畅度指标同时改善。

B1/B2 的平均有效视频码率分别为 1.87 / 2.13 Mbps，控制 RTT 均值为 34.79 / 32.52 ms；发送等待均值为 0.21 / 0.17 ms，解码均值约 4.12 / 4.14 ms。这组数据支持主要优化空间位于接收播放等待，不能当作满 20 Mbps 吞吐或端到端延迟认证。

原始报告 SHA-256、主机二进制摘要、两端统计与本地测试结果见 [脱敏数据](data/2026-11-13-cellular-playout-summary.json)。A1 使用先前主机，B1/A2 使用同一新主机二进制；C1 为临时候选，B2 为撤除候选后的最终构建。最终构建变化保留同一 WebRTC SDK、编解码与 RTP 配置，并增加报告说明。

## 本轮改动

新增 Mac CLI `--playout adaptive|realtime`，默认仍为 `adaptive`。`realtime` 通过现有 RTP playout-delay 扩展发送 `min_ms:0,max_ms:50`。手机沿用已安装的 UI 测试构建 7，没有为本次优化重新安装或上传 TestFlight。原端点、端口与配对文件不变。

这项改动针对 WebRTC 在解码前安排的播放等待。M157 收到最小延迟 0、最大延迟不超过低延迟阈值的扩展时，可提前安排可解码帧；帧依赖检查、拥塞控制、NACK/RTX、PLI 与既有桥接加密保持启用。50 ms 是播放策略提示，**不是端到端延迟承诺，也不是所有队列的硬截止时间**。没有使用已移除的 ZeroPlayoutDelay 配置，也没有更换 WebRTC 二进制。

实现依据是已固定的 stasel/WebRTC 157.0.0 对应上游提交 `95554e4a0c5c343fdc989387d9d0ce18e2a2294b`：

- [rtp_sender_video.cc](https://webrtc.googlesource.com/src/+/95554e4a0c5c343fdc989387d9d0ce18e2a2294b/modules/rtp_rtcp/source/rtp_sender_video.cc)：解析 `WebRTC-ForceSendPlayoutDelay` 的 `min_ms` / `max_ms`。
- [timing.cc](https://webrtc.googlesource.com/src/+/95554e4a0c5c343fdc989387d9d0ce18e2a2294b/modules/video_coding/timing/timing.cc)：低延迟播放路径。
- [frame_decode_timing.cc](https://webrtc.googlesource.com/src/+/95554e4a0c5c343fdc989387d9d0ce18e2a2294b/video/frame_decode_timing.cc)：提前解码仍保留最小节奏约束。

报告 schema 7 增加本进程的 playout 配置、RTP 载荷/头部字节、重传字节、传输字节与两端 SDP 是否协商该扩展。扩展协商成功不等于每个包都携带指定值；接收缓冲的 A/B 变化才是本次行为验证。旧手机报告没有新字段，其 `playout` 缺省值也不能用于推断主机是否发送低延迟提示。

## 测量方法

- 同一窗口内容自动轮换：真实 HDR 影片 60 秒、灰阶 45 秒。原片 23.976 fps，窗口时钟按 60 Hz 更新；60 fps 接收不等于原片有 60 个不同画面。
- 顺序运行对照，测量期间不运行编译、其他编码基准或第二条测试串流。
- 预热从每个报告首个有效媒体样本起排除 10 秒，使用 `summarize-lab.py --relative-warmup`，避免常驻主机启动时间被误作会话时间。
- 帧率使用累计解码帧差 / 观察时间；缓冲和编码数据是每秒统计区间均值的均值/P95。帧间距来自解码后渲染回调，不是物理屏幕扫描。
- 冻结、解码丢帧、RTP 丢包、NACK、应用队列丢弃同时检查。低缓冲不能以持续丢帧或停止恢复为代价。
- 控制 RTT 与接收缓冲单独报告，不把它们简单相加当作端到端延迟。

## 本地资格验证

两种模式分别进行 35 秒的 10 位 PQ RTP 回环、35 秒受控丢包测试和 20 秒真实 HDR 窗口回环。受控故障为第 5–15 秒每 100 个 RTP 包丢 1 个，第 15–15.2 秒丢全部 RTP。故障注入仅存在于 `--self-test --simulate-loss`，实际手机会话不注入。

两种模式都恢复到约 60 fps，解码丢帧均为 0；200 ms 中断各引发一次 SDK 冻结。低延迟模式的最大回调间隔约 217 ms，对照约 206 ms，不能声称它消除了断网冻结。真实窗口短测确认新主机的捕获授权、10 位色彩链路和扩展兼容。

复现命令（先构建并签名 Mac Release）：

```bash
python3 scripts/benchmark-playout.py --app /absolute/path/KKRemoteLabMac.app \
  --hdr --include-loss --duration 35
python3 scripts/benchmark-playout.py --app /absolute/path/KKRemoteLabMac.app \
  --hdr --window-id WINDOW_ID --duration 20
python3 scripts/summarize-lab.py .build/playout-bench/RUN_ID/*/ --relative-warmup
```

完整报告留在忽略的 `.build/` 下。基准工具记录二进制 SHA-256、参数、退出码并验证两端报告存在；本机回环不能替代蜂窝结果。

## 流量与适用边界

20 Mbps 是编码预算上限。本轮影片/灰阶的平均有效载荷明显低于上限，不能用这组结果证明持续 20 Mbps 或 80 Mbps 满载稳定。码率应随画面复杂度变化，不应为了让数字接近目标而填充无用视频数据。

接收端出现 RTX 计数、但发送端实际重传与 NACK 为零，并不足以证明网络丢包。[上游 rtp_sender.cc](https://webrtc.googlesource.com/src/+/95554e4a0c5c343fdc989387d9d0ce18e2a2294b/modules/rtp_rtcp/source/rtp_sender.cc) 的 payload padding 会通过 RTX 封装发送历史载荷用于带宽探测。本轮现象与此一致；尚未逐包认证其用途，因此保留为有源码依据的解释。没有关闭恢复或带宽探测来追求更小计数。

新增字节统计只覆盖相应 WebRTC/应用桥接层，不含全部 IP、Ponte 外层或运营商流量。不能把不同层、不同持续时间的计数相除后称为公网效率。

当前为无音频、固定尺寸、单视频流验证。音画同步、多窗口竞争、移动切网、持续高码率、不同 iPhone/iPad 的热稳定性，以及触控到光子的实际延迟仍需独立测试。保留 `adaptive` 回退，避免把单设备短时收益推广为所有网络上的最优配置。

## 蜂窝对照中的调度取舍

第一轮 `realtime` 的接收缓冲显著降低，但渲染回调间隔的区间 P95 变大：减少预先等待，也会减少吸收网络抖动的余地。因而临时增加 `balanced`（`min_ms:10,max_ms:30`）对照，保留基于时间戳的调度，而不是仅凭零冻结和平均 60 fps 就宣布流畅度全面提升。

该候选在本机无损与受控丢包均恢复到 60 fps；但约 142 秒蜂窝报告记录 3 次冻结、72 帧 SDK 丢弃，最大回调间隔约 2.77 秒，未通过验收，已从最终 CLI/枚举中移除。异常集中在前 15 秒，同时出现数百毫秒控制往返和发送降帧。**不能把它作为播放参数导致冻结的单变量因果证明**，也不能只排除这段再宣布通过。最终代码保留 `adaptive` 回退与 `realtime`，失败候选的报告和二进制摘要留存于数据文件。

页面报告的帧间隔不是屏幕的每帧呈现时间，本轮仍未完成光学端到端测量。

## 验证与交付

最终 Mac Release、iOS Simulator 构建、Mac 签名验证、Python 工具语法检查与 `git diff --check` 均通过。完成 8 组本地媒体资格测试和 5 段手机报告（含原始基线与失败候选），没有将故障注入用于实际手机连接。

当前 Mac 常驻测试主机显式启用 `--playout realtime`，手机沿用 USB 安装的构建 7 与已保存参数。代码和报告留在工作区，尚未 Git 提交、推送或上传新 TestFlight，界面改版仍可按此前要求审核。
