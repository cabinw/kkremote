# KKRemote：核心契约与实施路径

状态：**设计提案，尚未实现**。本轮没有创建 Swift Package、应用、网络服务或测试代码。本文独立设计接口，不依赖或复用竞品源码。首版范围为 **Mac 被控端 → Mac、iPad、iPhone 客户端**。查证日期：2026-11-12。

v0.3更新：A的Apple原生与窗口优先范围已选定；本轮建议原生libwebrtc优先验证、QUIC备选，见[传输复核](传输路线复核.md)。整屏延后；Tailscale/Ponte接入见[网络设计](网络与媒体传输.md)。本文件定义共用契约，后文原始A/B/C比较仅作历史背景，阶段顺序以[当前实施计划](分阶段实施计划.md)为准。

## 1. 桌面和窗口共用一种 Surface

建议把“捕获什么”和“如何传输、显示、输入”分开。DesktopSurface 与 WindowSurface 只在发现、几何与生命周期适配层不同；编码、会话、客户端渲染和反馈共用。

| 契约字段 | 用途与约束 |
| --- | --- |
| `hostID + sessionID` | 明确设备和本次会话；重连不能接纳旧会话输入；所有surface/cursor/input均保留host命名空间 |
| `surfaceID` | KKRemote 生成的不透明标识；系统窗口 ID、display ID 仅在主机内部映射 |
| `kind` | `display` / `window`；未来可加窗口组，不让它改变视频协议 |
| `generation` | 同一系统 ID 被复用或捕获对象重新绑定时递增，避免点击落入新窗口 |
| `layoutRevision` | 窗口位置、可交互内容范围、裁切、旋转或像素映射变化时递增 |
| `hostContentBounds` | 主机统一坐标系中的可交互内容矩形，以逻辑点表示 |
| `encodedExtent` | 编码帧实际像素尺寸，包括为编码对齐加入的填充 |
| `contentPixelRect` | 帧内对应主机可交互内容的像素矩形，排除填充与非交互阴影 |
| `sourceScale` | 采集源逻辑点到原生像素的比例；不能以客户端屏幕倍率代替 |
| `streamEpoch` | 编码器重建、格式或分辨率切换时递增；解码器丢弃旧 epoch 数据 |
| `frameID + captureTimestamp` | 关联帧、分片、反馈及显示时刻；时间戳注明时钟域 |

单窗口可用 `SCContentFilter(desktopIndependentWindow:)`，整屏可用 display filter；Apple 提供 `contentRect` 与 `pointPixelScale` 来表达采集内容范围和点像素比例。这些是 API 能力，不保证特定应用在最小化、隐藏或锁屏时持续产生有效帧。[Apple SCContentFilter](https://developer.apple.com/documentation/screencapturekit/sccontentfilter)、[pointPixelScale](https://developer.apple.com/documentation/screencapturekit/sccontentfilter/pointpixelscale)

建议状态机：`discovered → selected → streaming → resizing / suspended → streaming / closed`。关闭或权限撤回必须停止该 surface 的视频和输入；恢复时重新验证对象身份。窗口身份匹配不应仅靠标题。

Resize 是事务：客户端提交期望**逻辑尺寸**与请求编号；主机应用窗口约束后返回实际尺寸和新 revision；客户端等匹配新 epoch/revision 的首帧后才切换输入映射。不要先拉伸旧画面却继续按旧窗口坐标发送点击。

客户端本地布局另存`workspaceItemID/localRect/localZ/viewportTransform`，不写入远端几何。未来把A/B主机窗口放到同一画布时，本地移动窗口不隐式移动远端AXPosition。PeerSession作为每host实例提供服务，避免只能有一条全局连接的设计。[多主机预留](多主机工作区.md)

macOS 原生菜单、弹窗和子窗口可能是独立 surface。先设计 parent/child 关系和前台所有权，再决定是否合成；不能把“一个应用”假设为“一个矩形”。多个远程窗口也不能同时拥有主机键盘焦点。

## 2. 输入坐标契约

统一约定主机逻辑坐标为左上原点、向右和向下增加；多显示器允许负坐标。各 macOS API 的坐标约定由主机适配器显式转换，协议层不混用 AppKit、AX、CoreGraphics 的坐标。

输入消息必须绑定 `hostID、sessionID、surfaceID、generation、layoutRevision、controlLeaseID、inputSequence`（host可由已认证连接绑定，不能仅凭消息内hostID决定路由）。主机只接受当前对象与几何版本。过期点击返回 `staleLayout`，**不把旧点击自动重放到新布局**。旧版本的 key-up / button-up 要走独立的“释放已持有输入”逻辑，避免拒绝后产生卡键。

无旋转示例中，记编码帧尺寸为 `E`，客户端可见区域为 `V`，缩放为 `z`，以客户端逻辑点表示的平移为 `p`：

```text
fit = min(V.width / E.width, V.height / E.height)
scale = fit × z
origin = (V - E × scale) / 2 + p
capturePixel = (viewportPoint - origin) / scale
normalized = (capturePixel - contentPixelRect.origin) / contentPixelRect.size
hostPoint = hostContentBounds.origin + normalized × hostContentBounds.size
```

先拒绝 viewport 外和 `contentPixelRect` 外的点，再计算 hostPoint。边界采用半开区间 `[0, width)`，防止最右边像素映射到邻接窗口。旋转、镜像与裁切应进入同一个可逆变换矩阵并随 revision 更新；不能把旋转只当客户端 UI 效果。

### 可核算的例子

主机窗口：`(x=200, y=100, width=1000, height=600)` 逻辑点；完整内容帧 `2000×1200` 像素；客户端 viewport `1000×800` 点。

| 场景 | 计算结果 | 正确行为 |
| --- | --- | --- |
| 原始 fit，点击 `(250,250)` | fit=0.5；上下留白各 100；帧坐标 `(500,300)`；主机 `(450,250)` | 点击主机该位置 |
| 原始 fit，点击 `(250,50)` | 位于顶部留白 | 不发送主机点击 |
| 2× zoom，pan=`(100,-50)`，点击 `(250,250)` | scale=1；origin=`(-400,-250)`；帧坐标 `(650,500)`；主机 `(525,350)` | 按新变换映射 |
| 窗口移到另一个显示器，旧 revision 点击到达 | 映射已失效 | 丢弃点击并同步布局 |
| 同一窗口 ID 被新进程复用 | generation 不符 | 拒绝输入 |

这部分未来应优先验证：letterbox、非零及负窗口原点、阴影/填充、缩放平移、跨显示器、旋转、系统 ID 复用、resize 中的按下/释放。

## 3. Retina 是真实采集密度，不是输出尺寸标签

原生采集预算来自源窗口的真实 backing scale；客户端 Retina 只产生期望显示密度。输出 2000×1200 不意味着源有这么多细节。

对首版常见的 4:2:0 视频编码，可在源原生像素范围内按客户端预算等比缩小，再把宽高向下对齐到偶数。编码对齐约束应由实际选择的格式决定，不能硬编码为所有未来 codec 的通则。

```text
native = sourceLogicalSize × sourceBackingScale
r = min(1, clientPixelBudget.width / native.width,
           clientPixelBudget.height / native.height)
encoded = evenFloor(native × r)
```

例如 1000×600 点、源倍率 2、客户端预算 1600×1000 像素，选择 1600×960；若源倍率只有 1，最多保留 1000×600 的真实细节。想让应用真正绘制更高密度内容，需要源端适合的 HiDPI 显示环境，或改变应用窗口/渲染环境；仅增大采集输出无法补出细节。

按每帧实际内容几何校验设计值。`encodedExtent`、内容裁切与客户端 drawable 尺寸应分别可见于诊断面板，避免“窗口放大”“编码升分辨率”和“真正 Retina”混成一个开关。

## 4. 格式协商必须用完整能力交集

格式不是一个 `supportsHDR` 布尔值。至少包含 `codec / profile / chroma / bitDepth / primaries / transfer / matrix / range / dimensions / maxFrameRate`。同时记录是否硬件编码、是否硬件解码以及所选低延迟配置。

协商顺序：用户偏好阶梯 → 采集能力 → 编码器可创建且可实际输出的格式 → 客户端解码能力 → 客户端显示与色彩处理能力。未匹配时明确降级理由；不得静默把 SDR 标为 HDR。

| 示例候选 | 允许条件 | 不满足时 |
| --- | --- | --- |
| HEVC、4:2:0、10-bit、BT.2020、HLG 或 PQ | 源确有 HDR；传输/颜色元数据完整；两端 codec/profile 支持；显示链路支持相应 HDR 呈现 | 按已定义路径 tone-map 到 SDR，或切换其他可用格式 |
| HEVC、4:2:0、10-bit、SDR transfer | 两端支持相应 10-bit profile | 可用，但只能标 10-bit SDR |
| 4:4:4、8-bit、SDR | 编码、解码均支持具体 codec/profile；带宽与功耗预算允许 | 降为 4:2:0，或以后增加文字清晰层 |
| H.264、4:2:0、8-bit、SDR | 端到端可用的保底格式 | 若仍不可用，报不兼容而非建立黑屏会话 |

这些是候选配置，不表示每台 Mac/iPad 都有对应硬件支持。VideoToolbox 明确说明编码器不一定支持全部属性；应查询 session 支持属性，检查设置返回值和实际编码结果。低延迟模式也应按支持情况建立，不能只设置一个开关便宣称低延迟已验证。[Compression Properties](https://developer.apple.com/documentation/videotoolbox/compression-properties)、[VTSession](https://developer.apple.com/documentation/videotoolbox/vtsession-api-collection)、[低延迟编码示例](https://developer.apple.com/documentation/videotoolbox/encoding-video-for-low-latency-conferencing)

HDR 验收必须分别检查采集像素格式、编码 profile/位深、颜色元数据、解码输出以及最终显示效果；文字清晰度则另查源像素密度、色度采样与缩放插值。

## 5. 光标、触控、键盘分开建模

| 输入方式 | 画面与光标策略 | 交互策略 |
| --- | --- | --- |
| iPhone/iPad 直接触控 | 基础视频不烘焙光标；默认不显示鼠标箭头，可显示短暂触点反馈 | 单击、拖动、长按、两指滚动独立状态机 |
| 软件触控板 | 客户端绘制预测光标，并与主机确认状态校正 | 相对移动；明确加速度、拖拽锁定和滚动惯性归属 |
| Mac / iPad 外接鼠标 | 客户端光标覆盖层，图形/热点/隐藏状态单独更新 | 绝对或相对模式由会话协商，不按是否有触屏猜测 |
| 中文等输入法 | 输入法 UI 优先在客户端；文字提交与物理按键分离 | composition / commit / cancel 与快捷键分别传输，避免重复提交 |

ScreenCaptureKit 提供 `showsCursor` 控制捕获光标；KKRemote 可选择关闭基础视频光标，再建立自己的光标策略。但“独立光标”仍需要获取正确图形/热点/显隐状态，不应把固定箭头当作完整实现。[Apple showsCursor](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/showscursor)

连续 pointer move 可合并为最新值；点击、键盘、拖动开始/结束、输入法提交需可靠有序与去重。相对移动和滚动如果使用不可靠通道，应传累计量或有恢复机制，不能随意丢弃增量。断线/切换窗口时释放所有已按住键和按钮。

双指手势要先区分“远程应用滚动/缩放”和“本地查看画面缩放”。键盘弹出与手机旋转改变 viewport，但不应每帧触发主机 resize；建议手势稳定后提交尺寸事务。手机端可优先保留适合操作的窗口宽度，允许局部平移查看，而非一律把桌面文字压缩进竖屏。

## 6. 原始三条路径（历史比较，已由v0.3修正）

以下保留最初的分类，尚未测量工期或性能。v0.3明确：Apple原生采集/编解码与WebRTC可以组合，A/B不应再视为互斥；WebRTC也不限于公网场景。C仍是可叠加的后续画质路线。

| 路径 | 组成 | 优势 | 复杂度与主要风险 | 先做的验证 |
| --- | --- | --- | --- | --- |
| A：Apple 原生媒体，先局域网/VPN | ScreenCaptureKit → VideoToolbox → 原生客户端；可靠控制流 + 有期限媒体数据报，QUIC 为候选传输 | 易于逐项控制像素、颜色、帧队列、光标；契合首版 Apple 平台 | 中高；需自建分包、媒体恢复、优先级、带宽反馈；公网穿透和中继另做 | 两种 surface 共用管线；1×/2×像素；HDR元数据；弱网不积压 |
| B：WebRTC 媒体与数据通道 | 原生 capture adapter → WebRTC video/audio；DataChannel 承载窗口与输入语义 | 可复用 ICE、媒体反馈与成熟实时通信组件，后续跨平台更直接 | 中高；需维护构建与编码器接口；具体 HEVC/HDR/4:4:4 路径及多窗口策略需实证，不能靠 WebRTC 名称保证 | 实际支持的格式交集、弱网恢复、接入自定义采集时的复制和队列成本 |
| C：视频运动层 + 文字/静态细节层 | A 或 B 的基础视频，叠加分块精细更新、缓存与可靠恢复 | 有机会同时满足视频流畅与静态文字清晰 | 高；区域检测、分层时序、滚动/遮挡、缓存失效、色彩一致性、多编码预算复杂 | 同码率文本边缘改善是否值得；滚动时是否出现重影或旧块；CPU与耗电代价 |

QUIC DATAGRAM 本身不重传媒体，也不替应用定义帧分片和显示确认；其大小受对端协商与路径 MTU 限制，仍受拥塞控制。故 A 需要媒体帧 ID、截止时间、分片预算、恢复策略和解码/显示反馈，不能把 QUIC 当现成远程桌面引擎。[RFC 9221](https://www.rfc-editor.org/rfc/rfc9221.html)

WebRTC 的标准媒体与数据通道有不同传输栈：媒体用安全 RTP，数据通道使用 SCTP/DTLS/ICE，并支持不同可靠性/顺序选项。因此 B 应把视频接入媒体链路，输入与布局进相应数据通道；若把所有视频塞进可靠 DataChannel，便不能假定自动获得完整媒体调度能力。[RFC 8835](https://www.rfc-editor.org/rfc/rfc8835.html)、[RFC 8831](https://www.rfc-editor.org/rfc/rfc8831.html)

当前建议是保持A的原生媒体边界，优先验证原生libwebrtc的实时媒体机制，QUIC留作有条件备选。即使只用Tailscale/Ponte，这些机制也有价值；不以公网需求作为采用WebRTC的前提。文字画质达到可重复的测量瓶颈后，再决定是否引入C。

## 7. 执行时的阶段出口

1. **几何与窗口语义**：先用受控测试窗口证明桌面/窗口统一、resize 不错点、弹窗可操作、焦点不会串窗。未通过不进入画质调优。
2. **像素与媒体格式**：固定局域网，建立原生像素基线；验证文字色边、4:2:0限制、HDR/SDR切换；记录实际 codec/profile 与采集/编码/解码耗时。
3. **触控与端到端延迟**：直接触控、触控板、鼠标与中文输入分别验收；用高速拍摄等独立办法测 input-to-photon，不能用 RTT 冒充交互延迟。
4. **队列与弱网**：有界 capture/encode/send/decode 队列；覆盖延迟、抖动、丢包、带宽骤降、断线恢复，检查是否产生数秒旧画面积压与卡键。
5. **覆盖网与产品化**：按已选Tailscale/Ponte验证真实媒体路径，完善配对授权、权限状态与版本协商。自建公网穿透/中继已移出当前范围；传统整屏、多主机工作区与主机虚拟屏分别另行规划。

以上为后续实施的验收建议。本轮未运行这些验证，也没有性能、兼容性或画质达标的实测结论。
