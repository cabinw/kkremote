# HDR 真实窗口串流接入计划

2026-11-13。以下第 1–5 节保留实施前的方案与风险假设；最新实现和验收结果见 [HEVC Main10 HDR 验证](../testing/HEVC-Main10-HDR验证.md)。本地已打通 10 位硬件编解码、RTP、真实 HDR 窗口、系统显示层、丢包恢复和 SDR 回退。

需要同时更新 Mac 主机和 TestFlight 客户端。构建 5 保留为 H.264 SDR 对照，不能仅靠主机配置接收和正确显示 HDR。继续采用原生 WebRTC + 固定 UDP v2/socket；本次不因新增 HDR 而更换传输协议。窗口交互、移动布局、音频、Tailscale 与整屏模式仍不纳入本轮。

## 1. 已核实的现状

| 环节 | 当前证据 | 对 HDR 的影响 |
|---|---|---|
| 窗口捕获 | `WindowCaptureSource.swift` 显式配置 BGRA、sRGB、SDR | 源端已经限制为 SDR，必须改采集配置 |
| 编解码 | `PeerEngine` 只注册 `LabH264EncoderFactory` / `LabH264DecoderFactory` | 构建 5 没有 HEVC Main10 接收路径 |
| SDK | 固定 stasel WebRTC 157.0.0，包 revision `c6cde72c7638acf8dc2b070aaecca054e9e20720` | 包版本不是上游 WebRTC 源码 revision；需要另外建立源码与产物对应关系 |
| 默认工厂 | 在已安装 Mac framework 中查询支持列表，编码、解码均无 HEVC | 不能直接改用默认工厂便宣称支持 HEVC |
| 原生帧 | `RTCCVPixelBuffer.supportedPixelFormats()` 返回 32ARGB、BGRA、420f、420v | 没有列出 P010 / x420、xf44；直接塞入 HDR buffer 未经过支持验证 |
| 底层 RTP | Mac 二进制含 H.265 packetizer、depacketizer、bitstream parser 的字符串 | 只证明相关实现痕迹存在，不证明应用工厂、协商、10 位回调已贯通 |
| 显示 | Mac 用 `RTCMTLNSVideoView`，iOS 用 `RTCMTLVideoView`，应用未配置 HDR/EDR | 必须新增完整 HDR 显示路径，不能只修改解码器 |
| 信令 | 当前 `SignalMessage` 无格式能力字段；未知消息类型报错，重复 SDP 也报错 | 能力扩展与旧构建兼容、格式切换均需明确设计 |
| 导出 | 现有解码截图强制 RGBA8/sRGB PNG | 只能作 SDR 预览，不能作为 HDR 保真证据 |

在本机 macOS 27.2.1 上只读查询 `captureHDRStreamCanonicalDisplay` 预设，得到 `xf44`（10 位 4:4:4 全范围）、`DisplayP3_PQ`、`ITU_R_709_2` matrix、canonical 动态范围。**这些是预设配置值，不是已捕获到 HDR 内容的实测帧附件。** 实施时必须检查每帧像素与色彩附件。

当前 Xcode 头文件也列出 x420，但不能据此断言最低支持系统 macOS 15 的所有组合都能直接输出它。主机现有最低版本为 macOS 15、客户端 iOS 18；暂不提高版本门槛。Apple Silicon HDR 捕获能力与真实设备解码/显示能力分别检测。[Apple HDR 捕获说明](https://developer.apple.com/videos/play/wwdc2024/10088/)

## 2. 推荐的首条 HDR 路径

```mermaid
flowchart LR
  W[真实窗口中的 HDR 内容] --> C[ScreenCaptureKit canonical HDR]
  C --> P[保留 10 位精度的像素与色彩转换]
  P --> E[VideoToolbox HEVC Main10]
  E --> R[WebRTC RTP/SRTP 与恢复调度]
  R --> B[现有 UDP v2 / Surge Ponte]
  B --> D[VideoToolbox 10 位硬解]
  D --> V[带正确色彩信息的 HDR 显示层]
```

第一档选 **HEVC Main10、4:2:0、10 位、BT.2020 / PQ、2560×1440、60 fps 目标、20 Mbps 视频预算上限**。这是拟实现的传输格式，不是已经测得的能力。主机硬件会话、实际 SPS 与接收端都通过后才公告该格式。Main10 或 10 位本身不代表内容一定是 HDR。[Apple Main10 API](https://developer.apple.com/documentation/videotoolbox/kvtprofilelevel_hevc_main10_autolevel)

捕获优先使用 canonical 预设，避免沿用针对主机屏幕的 local 映射。若系统能够直接产生所需 x420 与色彩配置且实测正确，可省掉转换；否则把 xf44 / P3-PQ 用一次有界 GPU 转换变为编码器需要的 x420 / BT.2020-PQ。转换包含色域、YCbCr 矩阵、全/视频范围与色度采样，不能只重新贴 BT.2020 标签。避免经过 BGRA8、8 位 I420 或 CPU 每帧往返。

首轮使用 PQ，暂不同时扩展 HLG、Dolby Vision、4:4:4 或 AV1。符合相应元数据条件前只称 PQ HDR 路径，不宣称已经完成 HDR10 或 Dolby Vision 支持。桌面白色应保持合理的 SDR 白点；高光更亮不能变成整张文档整体过曝。新系统的 SDR range preservation 能力可做条件优化，不能成为 iOS 18 基线的唯一依赖。

## 3. 改动清单

| 模块 / 文件 | 必需改动 | 验证方式 |
|---|---|---|
| `WindowCaptureSource.swift`、`LabVideoSource.swift` | 按协商格式创建捕获；HDR preset；记录 pixel format、primaries、transfer、matrix、range 与有效源帧率 | 读取实际 buffer 附件，检查包含超出 SDR 范围的已知内容 |
| 新增像素/颜色适配模块 | 原生 10 位 buffer 生命周期、GPU 转换、有限缓冲池；保留时间戳与附件 | 精度测试图、梯度、肤色、白点；检查转换前后格式及 GPU 耗时 |
| `LabH264Factory.swift`、新增 VT HEVC 编解码器 | 兼容 H.264；新增 Main10 硬件编解码、真实能力探测、码率动态调整、关键帧请求、错误恢复 | 实际输出 SPS/profile/bit depth，实际解码 buffer，不只检查设置返回成功 |
| WebRTC SDK 及原生桥接 | 补齐 H.265 codec-specific 回调、native 10 位帧、参数集与色彩信息；固定可复现产物 | Main10 RTP 回环、NAL 分片/重组、丢包后恢复、Mac/iOS 真机互通 |
| `PeerEngine.swift`、`SignalTransport.swift`、`LabModel.swift` | 格式能力交集；在确定输出格式后启动捕获；协商 HDR/SDR；格式变化重建会话 | 构建 5 SDR 回退，新客户端 SDR/HDR，缺失能力、失败和重连 |
| `LabApp.swift`、新增 HDR renderer | 接收 10 位解码帧，正确处理颜色和显示能力，限制显示排队 | HDR 与系统参考播放对照；实际呈现帧率、headroom、过期帧与队龄 |
| `EncoderTelemetry.swift`、`LabSample`、报告 | 捕获→转换→编码→发送→解码→显示的阶段计数/耗时，HDR 实际格式与回退原因 | 能定位哪一步转成 8 位、丢附件、降帧或堆积 |
| 构建脚本 / `project.yml` / SDK 依赖 | 若替换 SDK，固定源码 commit、构建参数、补丁、checksum、符号与许可证；更新构建号 | Mac Release、iOS 真机 archive、内部 TestFlight 实装 |

### SDK 是第一道技术门槛

现有 SDK 的 H.265 底层痕迹可复用，但公开 ObjC 接口不足以证明完整路径。查阅的上游 main 实现中，编码桥接对 codec-specific 信息只显式转换 H.264；`RTCCVPixelBuffer` 的转换处理与本地查询的 8 位列表相符。上游 main **不是**已安装 M157 二进制的精确源码证明。

先做最小 Main10 编解码 + RTP 回环，检查 codec 类型能否正确到达 H.265 分包器、原生 10 位帧是否被转成 I420、VPS/SPS/PPS 与关键帧能否完整重建。预计需要自建固定版本 WebRTC，至少维护 Apple 原生帧/codec 桥接的有限补丁；若证明应用侧工厂即可完整通过，再缩减 SDK 改动。不给“仅换编码器几行代码”或“不需要自建 SDK”承诺，也不先深改拥塞控制。

参考：[ObjC 编码桥接](https://webrtc.googlesource.com/src/+/refs/heads/main/sdk/objc/native/src/objc_video_encoder_factory.mm)、[CVPixelBuffer 适配](https://webrtc.googlesource.com/src/+/refs/heads/main/sdk/objc/components/video_frame_buffer/RTCCVPixelBuffer.mm)、[H.265 RTP 分包](https://webrtc.googlesource.com/src/+/refs/heads/main/modules/rtp_rtcp/source/rtp_packetizer_h265.cc)。

### 编码和传输

VideoToolbox 先验证 Main10 硬件会话、实时模式、关闭帧重排及实际输出；低延迟 rate-control 属性需独立探测，不能沿用 H.264 的成功结果。编码器必须响应 WebRTC 下发的动态码率，按输出字节和帧率检验约束。20 Mbps 为视频预算，包含 RTP/加密/覆盖网开销后的线速会更高；可压缩内容不必填满预算。

继续复用 WebRTC 的 pacing、拥塞反馈、NACK/PLI 与现有 Ponte 桥接；桥接转发的是媒体数据报，预期无需新增外层协议版本。必须复测 HEVC 关键帧突发、分片边界、重排、丢片、参考帧恢复及重连，不把 H.264 的恢复结果直接外推。只在编码前丢弃过期原始帧，避免任意删除已编码参考帧造成长期花屏。保留当前发送队列时限与诊断，不能靠扩大接收缓冲掩盖突发。

### 色彩与显示

格式契约包括 `codec/profile/bitDepth/chroma/primaries/transfer/matrix/range/dimensions/fps`，另记录 HDR 元数据及来源。优先由 HEVC 位流的 VUI/SEI 传递可编码的信息，并核对解码生成的 format description / pixel buffer 附件；信令描述用于能力与一致性检查，不能代替正确位流。窗口是系统合成结果，不能把某个原始视频文件的 mastering 数据无条件复制到整个窗口，也不伪造峰值亮度元数据。

第一阶段优先以 `AVSampleBufferDisplayLayer` / 系统视频渲染器验证 HDR 色彩和低延迟呈现，替换现有 RTC 默认 view 的 HDR 路径；限制待呈现队列，处理时间基准、过期帧、前后台 flush 和新会话首帧。若系统层的实测排队不能满足预算，再采用自定义 Metal EDR renderer：正确采样 10 位平面，配置 HDR 色彩空间/高精度 drawable，并按实际 headroom 映射。系统层也作为 Metal 色彩对照，未来多窗口仍可各自拥有显示层。

显示能力要区分“能解码 Main10”“屏幕潜在 HDR 能力”和“当前可用 EDR headroom”；亮度、系统状态改变时不能一直按固定峰值显示。当前 headroom 下降通常由显示层适配，不应每次触发编解码器切换。首轮不实现移动布局，但必须提供可见的 HDR/SDR 状态及原因。[Apple Metal HDR](https://developer.apple.com/documentation/metal/displaying-hdr-content-in-a-metal-layer)、[iOS EDR](https://developer.apple.com/videos/play/wwdc2022/10113/)

### 与构建 5 的兼容

新主机在现有 offer / answer 消息中增加可选字段，并提供 H.264 SDR 保底候选。旧客户端的 answer 不包含新能力且只选择 H.264 时，主机明确启用 SDR 捕获/色调映射。旧客户端遇到未知消息类型会断开，因此不能直接向构建 5 发送新的 `capabilities` 消息类型。实现时验证旧版 JSON 解码对新增可选字段的行为。

新客户端仅在 Main10 解码及 HDR 显示路径都验证可用时声明支持；格式由 SDP 选择与应用能力共同确定，不能只看“支持 HEVC”布尔值。用户强制 HDR 而能力不满足时给出具体失败理由；自动模式允许明确显示的 SDR 回退。第一轮 HDR/SDR 切换通过重建会话完成，刷新媒体密钥、丢弃旧帧并对齐格式代际；不在目前拒绝重复 SDP 的会话中硬塞热切换。

## 4. 分阶段实施与验收

| 阶段 | 工作 | 进入下一阶段的条件 | TestFlight |
|---|---|---|---|
| A：最小能力闭环 | 固定 SDK 源码映射；已知 10 位帧→Main10→RTP→硬解；验证 native buffer、SPS、附件和关键帧 | 1440p60 回环得到真实 10 位帧；确定 SDK 补丁范围；没有静默 8 位转换 | 暂不上传 |
| B：真实 HDR 窗口 | canonical 捕获、必要 GPU 转换、HDR renderer；用白底滚动+HDR60 视频混合窗口 | 捕获/编码/解码/呈现格式一致，白点/高光正确；完成本机及 15mac LAN 对照（设备能力允许时） | 本地真机验证后上传首个 HDR 内部构建 |
| C：异地 iPhone | 新内部构建 + 同版本 Mac，经原 Ponte 地址与固定配对码接收；SDR 与 HDR 分别跑 10 分钟 | 真实 1440p、动态源约 60 fps；统计实际码率、帧间隔、卡顿、队龄及分段延迟；用户确认画质 | 更新后才能测试 HDR |
| D：稳定性 | 30 分钟 HDR、突发/丢包恢复、断线重连、前后台、HDR/SDR 重建；条件允许再覆盖 iPad/Mac HDR/SDR 屏 | 不持续累积排队，无错误色彩状态与旧帧串入；失败可定位并回退 | 按修复需要增量更新 |

60 fps 验收必须使用真正按 60 Hz 更新的源。静态窗口不产生 60 个新画面属于正常行为。沿用主机 60 Hz；在日志中记录实际刷新率，先补显示变化检测/捕获恢复，不能重复把源端约 48 fps 当成网络上限。

测试内容分三类：

- 白底文档/代码滚动：比较细字、彩色边缘与 SDR 白点；HDR 不等于 4:4:4，不自动解决色度采样引起的文字问题。
- 已确认 PQ/HLG 和实际 60 fps 的 HDR 视频 + 参考灰阶/高光梯度：检查高光层次、暗部、断阶和色偏。上轮 Big Buck Bunny 素材是 SDR，不能用来证明 HDR。
- 同一个真实窗口的 SDR 与 HDR A/B：固定窗口尺寸、显示刷新率、网络、设备状态和测试片段；分别报告 H.264 SDR 与 HEVC Main10 HDR，避免把编码器差异全部归因于 HDR。

建议先增加一组 HEVC Main10 SDR 对照，以分离 codec、10 位与 HDR 映射成本；该组只在主路径初步跑通后做，不延迟首个可用 HDR 构建。

每轮排除固定预热时间，保留捕获/提交/编码/解码/呈现的累计计数和秒级窗口。针对持续 60 fps 动态内容，初始目标为稳态平均至少 59.5 fps，逐项列出低于 55 fps 的秒级区间与超过 100 ms 的显示间隔；无主动丢包时目标均为零，不能用平均数掩盖冻结。该门槛是拟定目标，当前 SDR 异地视频的主机均值仍是 58.87 fps，并未先行通过。

延迟先要求 HDR 相对同路径 SDR 的处理/呈现 P95 增量不超过一个 60 Hz 帧周期（约 16.7 ms），并报告完整分段数据；这是性能预算，不是已测结果。控制 RTT 继续单独列出。跨设备时钟未校准且未给出误差范围时，不报告绝对单向端到端延迟；显示提交/回调也不等于光学显示时刻。可用同场高速拍摄对基准链路做独立校准。

功耗/温度、硬解使用情况、显示 headroom 与掉帧一并记录。原始全帧随机噪声仍是独立未通过压力项，不替代本轮真实 HDR 窗口的验收。

## 5. TestFlight 安排与本轮交付边界

**必须发布新的 iOS 构建**，至少包含 Main10 解码、HDR 显示、格式能力协商和诊断。Mac 同时更新；构建 5 只能继续测试 SDR。无需重建 App Store Connect 应用或测试组，构建号使用后台下一个可用值，不预先假定一定是 6。

继续通过现有内部测试组分发；内部测试不走外部 TestFlight Beta App Review，但仍需 Apple 完成构建处理与适用的合规状态检查。上传成功不能当作手机已经可见，仍需确认组关联、可安装状态与设备实际安装的构建号。[Apple TestFlight](https://developer.apple.com/testflight/)

原配对码与 Ponte 地址/端口保留，HDR 本身不要求重新配对。实施结果表明：现有 M157 二进制可经公开编解码工厂贯通 H.265 RTP，当前固定尺寸、单层、原生 CVPixelBuffer 路径无需 SDK 补丁；不能把该结论外推到 I420 转换、动态缩放或多层编码。本机 ScreenCaptureKit 直接输出 x420 / BT.2020-PQ，未实现额外 GPU 转换；其他系统若未输出约定格式会明确失败。后续状态以验证记录为准。
