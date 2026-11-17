# Ponte 接收调度与丢包恢复

本轮延续 80 Mbps 上限、1920×1080、60 fps 的 H.264 SDR 动态噪声压力测试。发送端为 Apple Silicon Mac，接收端为 Intel MacBookPro11,4（15mac）。窗口、HDR、Tailscale 和公网部署继续后置。

## 可复现的变更

新增可选 `socket` 外层 UDP 实现，保留 Network.framework 作为兼容与 A/B 基线。两个实现使用相同 v2 AEAD 封装、同一配对信令与 WebRTC ICE/DTLS/SRTP/SCTP，支持互通；没有更换视频协议、禁用拥塞控制或降低噪声源复杂度。实验界面中通过“UDP 实现”选择，命令行使用 `--bridge-transport socket`。当前默认仍为 `network`，socket 尚未在移动真机和 IPv6 上完成资格验证。

- **BSD 接收调度**：非阻塞 socket 配合 DispatchSourceRead，每轮最多处理 32 个外层包，复用接收缓存；保持串行认证与协议处理，给计时器和停止操作留出调度机会。
- **有界发送**：sendto 立即提交或计入错误，不无限重试、不增加无界排队；既有 256 包等待上限、25 ms 应用等待期限保持不变。接收/发送 socket buffer 请求 256 KiB，报告保存实际接收容量。这不保证内核或覆盖网的总排队时间。
- **端点验证**：系统解析原始 `.sgponte`，不替换为 LAN 地址。主机只有验证足量认证探测后才能固定来源 IP/端口；之后拒绝其他来源。v2 要求双向 1280 字节探测；保留 v1 显式兼容。
- **Network 对照**：通过 `--receive-depth 1|16` 控制接收请求数；16 个请求的完成回调仍在同一个串行队列。此参数对 socket 实现无调度作用。
- **新增观测**：外层已认证序列缺口、乱序与最大间隙；RTP 重传、PLI；接收目标/最低 jitter delay；解码渲染回调帧间距；编码 QP 与回调拒绝数。报告 schema 升为 4。

## 诊断边界

外层序列缺口是当前最高序号减去接受的不同序号数。晚到包可填补缺口，发送前的应用丢弃也会造成缺口；必须结合发送丢弃、内层 RTP、NACK 等指标分析。它不能单独证明 Surge、网络或内核中的某个具体丢包点。

原有 `localSocketDrops` 混合了不匹配的本机 ICE 来源、未设置目标时的发送、尺寸无效和 sendto 错误。本轮将这些类别分别输出，不能把旧报告的这个计数全部解释为发送拥塞。

帧间距来自 RTCVideoRenderer 回调，不是显示器扫描或触控到光子的时延。send/decode/jitter 指标为每个统计区间的均值；本文 P95 是这些区间均值的 P95。正式端到端延迟仍需独立真机测量。

## 使用与复测

先构建并向两台 Mac 部署同一 Release App。`benchmark-remote.py` 在测试开始前比较两端可执行文件 SHA256；配对码经已有 SSH 的 stdin 传输，报告不保存密钥或主机地址。

```bash
python3 scripts/benchmark-remote.py \
  --ssh YOUR_EXISTING_SSH_ALIAS --remote-app /absolute/path/KKRemoteLabMac.app \
  --host YOUR_HOST.sgponte --network 'Surge Ponte' \
  --route fixed-udp-v2 --bridge-transport socket --pacing interactive \
  --duration 300 --resolution 1920x1080 --fps 60 --mbps 80 --pattern noise
```

LAN 原生对照使用可达 LAN 地址、`--network LAN --route direct-ice`；LAN 桥接对照使用相同地址、`--route fixed-udp-v2`。原生 ICE 不使用外层 bridge，所以其报告里配置的 bridgeTransport 不代表该实现参与了媒体链路。

原始日志保留在忽略的 `.build/remote-bench/`；脱敏汇总随测试完成后记录。两台机器位于同一局域网，Surge 的 Ponte 诊断显示使用 LAN 通道。这是实际跨机 Ponte 测试，但不是异地公网 Ponte 的性能结论。

## 2026-11-13 测量结果

80 Mbps 是发送上限，表中码率是视频实际有效载荷；保持相同 1080p60 噪声源。均值/P95 排除前 10 秒预热，丢包/NACK/冻结为全会话累计。

| 路径 / 实现 | 时长 | 实际 Mbps | 接收 fps 均值 | 发送等待 P95 ms | 接收缓冲 P95 ms | RTP 丢包 / NACK | 冻结 |
|---|---:|---:|---:|---:|---:|---:|---:|
| Ponte / Network 深度 1 | 90 s | 70.94 | 57.51 | 4.29 | 91.33 | 5428 / 348 | 1 |
| Ponte / Network 深度 16 | 90 s | 55.14 | 47.65 | 5.81 | 77.36 | 0 / 0 | 2 |
| Ponte / socket 短测 | 120 s | 73.32 | 59.88 | 2.36 | 95.23 | 0 / 0 | 0 |
| LAN / 原生 ICE | 300 s | 73.71 | 59.92 | 2.11 | 56.16 | 0 / 0 | 0 |
| LAN / socket v2 | 300 s | 73.53 | 59.82 | 2.00 | 38.07 | 279 / 22 | 0 |
| Ponte / socket v2 | 300 s | 70.65 | 57.93 | 2.51 | 46.02 | 0 / 0 | 2 |

完整区间汇总、构建 SHA256、参数和运行 ID 见 [脱敏数据](data/2026-11-13-socket-summary.json)。三次 300 秒测试顺序执行；测试期间不运行构建或其他媒体基准。其二进制 SHA256 相同，之后追加的本机丢弃分类与实验界面选项已重新构建验证，不把旧二进制的指标冒充为新二进制的新测量。

**结论：80 Mbps 档尚未稳定到 60 fps。** 两分钟 socket 结果已接近 60 fps，但五分钟 Ponte 对照不能通过稳定性验收。它消除了本轮观察到的外层序列缺口、RTP 丢包和 NACK（两个方向应用队列也没有丢弃），仍发生 2 次冻结，其中 1 次在预热后。不能据此认定所有冻结来自丢包恢复。

### 当前证据指向

- Network 深度 1 对照收到的外层认证序号存在 7210 个缺口，应用发送队列无丢弃；同时出现 5428 个 RTP 丢包与 348 次 NACK。缺口位于外层传输/接收路径范围，具体内核、Surge 或链路丢包点尚未逐层抓包确认。
- 将 Network 接收深度改成 16 可以出现零丢包，但码率分配波动与降帧仍明显。仅增加待接收请求数不是完整解法。
- socket 五分钟 Ponte 的接收缓冲均值 29.41 ms、区间均值 P95 46.02 ms；两分钟结果 P95 仍达 95.23 ms。缓冲有明显运行间差异，不能宣称已稳定降低到 46 ms。
- 五分钟 Ponte 的低帧率发生时，发送端也已经降帧。开头分配给编码器的码率约 11–27 Mbps，QP 为 51，回调用时约 6–9 ms；后段约 213 秒再次出现 23–27 Mbps 分配和 43–48 fps。编码回调拒绝数为 0。证据更符合高复杂度噪声源达到量化极限后，码率分配与帧率适应相互作用；这是待验证解释，不是已证明的唯一根因。
- 约 222 秒出现预热后冻结，最大渲染回调间隔 196.94 ms；没有同步的 RTP 丢包或 NACK。下一轮需对齐拥塞控制估计、帧产生/编码时间、包发送与帧到达节奏，验证 `smooth` pacing 的影响，再决定是否修改默认参数。不会用强行抬高最低码率、关闭拥塞控制、缩小像素或简化噪声源来宣称达标。

## 验证与交付范围

已通过信令测试、v1/v2 封装与乱序/重放测试、Network/socket 双向组合的真实 UDP 16 KiB 分片往返、错密钥拒绝、小探测拒绝及来源固定测试；Mac Release、iOS Simulator 构建与 iOS 构建 3 签名归档通过。socket 目前仅支持 IPv4，IPv6 使用 Network.framework；移动真机与异地 Ponte 的性能仍待测。

用户随后开始异地 iPhone 测试，因此先发布包含上述功能的内部测试包并启动专用会话，暂缓下一轮 15mac pacing 对照，避免手机交互测试和性能基准互相干扰。窗口体验与 Tailscale 仍未展开。
