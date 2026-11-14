# iOS 真实体验接入交接

## 2026-11-15 精确像素与恢复更新（当前，USB 42）

真机已通过 Chrome 灰阶/细线、真实 HDR 影片、Excel、横竖屏、双向切窗及断开重连回归。源窗口 645×1309 点、编码与 AV 显示层均为 1290×2618 像素；横屏为 2442×1290。`pixelExact` 与实际显示遥测 `displayOneToOne` 均为 true；竖屏视频区域底部剩余一行，不伸缩也不接受输入。

iOS 会话的几何修改已整合；通信侧额外在 `HDRVideoView`/`ReceiverTelemetry` 记录实际 layer 像素，`IOSLabView.viewerState` 增加 `displayOneToOne`、`surfacePixelX/Y/Width/Height`。保留 `geometryContent`、实际解码尺寸与源点尺寸检查、显示/触控同一几何；不能再外包一层 fit 或把这几个尺寸混用。wire 格式和连接偏好不变。

Host 原生窗口进入和恢复均改为缩小、移屏、恢复目标尺寸，并验证 AX 与窗口服务器实际结果；重选等待恢复完成。Chrome 与宽 1688 点的 Excel 均恢复到原位置和尺寸。原生目标被应用限制时报告失败，不把中间尺寸当成成功。小窗/最小尺寸不支持、屏幕消失、进程崩溃恢复仍需后续产品化。

实验工作区现在在原显示器右侧，内屏仍为 3456×2234 像素 / 1728×1117 点 / 60 Hz，左侧 Dock 不再迁移；未改 Dock 偏好。原端点 Host 指针 `.build/iphone-resume-20261114/ready-host.json`，helper 状态 `.build/pixel-exact/workspace.json`，不要继续使用构建 41 的旧 helper/进程指针。保留 HDR、60 fps、20 Mbps、1440p 面积预算；虚拟显示为 2× / EDR 5，仍是当前系统的私有 API 实验。

测试已结束，USB 42 普通启动，无自动诊断倒计时，Host 保持监听；未更新 TestFlight。客户端可继续用保存的连接配置体验。两轮约 52 秒的帧率中位 60、无解码丢帧/显示失败，但不代表长期冻结已解决。当前是 Wi-Fi + Ponte，不归类为蜂窝复测。完整边界、源 P010、显示层、细线对照和窗口恢复证据见 [专项报告](../testing/精确像素与窗口恢复验证.md)。

## 2026-11-15 HDR + HiDPI 真实应用更新（构建 41 历史）

USB 构建 41 已完成真实 Chrome 和 Excel 的 1290×2620 原生源 / 解码验证；60 fps / 20 Mbps / 1440p 面积预算及原端点不变。工作区已从 SDR helper 升为实验 HDR helper：2×、60 Hz、EDR 5。浏览器高光原始 P010 值超过文档白色，手机保留到 PQ 724、EDR 8；已通过 App 重启后 HDR 显示选项保留测试。当前普通启动，没有诊断倒计时或正在执行的 XCTest。

正文大小靠源应用在栅格化之前的 150% 内容缩放补偿：本轮是自有浏览器页面 CSS zoom 和 Excel 工作簿 zoom，并未实现通用自动适配。菜单/标题栏仍是系统 2×。原生源与手机视频尺寸一致，但 2620 行偶数编码和 2619 行视口间还有微小 fit 缩放；后续 iOS 像素对齐应与通信侧协商有效内容矩形和 padding，不能把源端 displayScale 强写为 3。

通信侧只新增实验 HDR helper、测量/夹具和 Chrome 精确标题后缀匹配，保留现有控制身份校验；没有修改客户端布局/手势。两组接收 fps 中位 60、解码约 3.8 ms、显示失败 0，但冻结计数 4 / 2 未清零，继续留档。真实 Chrome/Excel 断开后回物理屏，但宽窗口恢复不完整，需后续修复 Host 双阶段恢复。

原端点 Host 的最新指针仍是 `.build/iphone-resume-20261114/ready-host.json`，实际工作区 ID 读取 `.build/hdr-workspace/workspace.json`。私有 CoreGraphics helper 仅是本机 macOS 27.2.1 原型，不直接作为正式发布依赖。完整数据和真机截图见 [HDR + HiDPI 真实应用验证](../testing/HDR-HiDPI工作区真实应用验证.md)。以下构建 40 的 SDR 描述保留为历史对照。

## 2026-11-15 源端原生像素专项更新

用户已重新授权通信侧使用真机验证画质。当前 USB 为构建 40，原 Ponte 地址、端口和配对文件保持不变；自建实窗已验证原生 1290×2620 采集及真机接收，横屏为 2442×1290，切回和断开恢复均通过。没有改动客户端手势、键盘或布局；客户端继续传递视口 `displayScale`，输入按服务器确认的源点尺寸换算，不假定手机点数等于 Mac 点数。

当前原端点 Host 显式启用 `--native-workspace-display-id`，配合独立临时 HiDPI 工作区；运行指针为忽略的 `.build/iphone-resume-20261114/ready-host.json`。自建夹具以 150% 字体/矢量重绘保留手机字号，普通应用需要各自的内容缩放。此工作区只有 SDR 显示能力，不能把 Main10/PQ 标签当作虚拟工作区 HDR 已通过；普通物理 HDR 路径仍保留。详情、证据及退回步骤见 [原生源像素工作区验证](../testing/原生源像素工作区验证.md)。偶发冻结继续后置，未启动新长测。

以下为构建 12 阶段的历史接入基线，涉及当时设备占用和构建号的描述不覆盖上面的最新状态。

更新：2026-11-14。当前阶段收敛为 **通信 v1 接入基线**，iOS 研发使用真机推进真实窗口体验。通信会话暂停所有主动测试，不再占用手机、安装或启动 App、打开投屏预览、切换窗口或调整显示模式。既有 Mac Host 保持普通监听，原地址、端口和配对码不变。

此次收敛是研发阶段决定，不代表所有性能门槛已通过。偶发冻结、关键帧间隔、停止尾帧及内存长测留档，暂不作为 iOS 体验接入的前置条件。通信侧只在出现接入阻塞、接口缺失，或用户重新安排测试时继续相应工作。

## 接入范围

| 现在可以直接使用 | 当前边界 |
|---|---|
| 真实 Mac 窗口目录、选择、切换、停止观看 | 一次一个观看者、一个窗口；切换会重建媒体 |
| 现有 Ponte 视频链路 | 固定 UDP v2 / socket，IPv4；原端点继续使用 |
| HEVC Main10 / PQ 与 H.264 SDR 协商 | 首选 Main10；按能力回退，查看实际解码格式 |
| 视频与移动视口集成 | 复用 `ColorManagedVideo`，外层处理缩放、平移、安全区、横竖屏 |
| 状态、统计及错误处理 | `LabModel` 是当前入口；不是已经独立发布的 SDK |
| 真实点击、滚动、中文输入、远端 resize | 正式窗口协议尚未实现；iOS 的 WPS 原型另有本机控制通道 |

第一步可以让现有客户端外观直接承载真实远端视频，完成选窗、观看、切换与恢复体验。不能把本地手势预览当作远端已执行。要把 WPS 原型的完整编辑体验迁移到异地真机，需要补正式控制协议与 Mac 执行端；这是一项产品接入工作，不必先解决所有偶发传输问题。

## 固定基线

- 媒体：2560×1440、60 fps 上限、20 Mbps 预算；Main10 BT.2020 / PQ，能力不足回退 H.264 SDR。
- Host：`interactive` pacing、`realtime` playout hint、10 秒周期关键帧、捕获深度 3、桥接接收深度 16；拥塞控制及 NACK / RTX / PLI 保留。
- 正常使用关闭逐帧 trace、故障注入、诊断倒计时。不要带 `--media-diagnostics-run` 或 `--media-diagnostics-seconds` 启动体验包，否则会到时自动断开。
- 连接偏好沿用 `ConnectionPreferences`；短码保存在现有 Keychain，本地缺失时从用户已有设置恢复，不生成新码。签名与默认连接配置保持在忽略的本地文件中。
- 当前真机已安装 USB 构建 12；未为本次收敛更新 TestFlight。源码快照是交接时的工作区版本，包含 iOS 并行改动，不宣称它与构建 12 的全部 UI 字节一致。

详细参数见 [配置快照](transport-v1-profile.json)。iPhone 已验证一次 10 分钟真实图纸窗口：59.987 fps、实际 11.829 Mbps、SDK 冻结/解码丢帧为 0，5 分钟后内存中位约 91 MiB，见[实机报告](../testing/iPhone蜂窝Ponte构建12复测.md)。20 Mbps 是预算；10 分钟不替代 30 分钟验收。

## 客户端实际调用顺序

当前接口为同一 Swift App target 内的类型，没有独立 framework / Swift Package，也没有 `public` SDK API。优先在既有 `KKRemoteLab` 目标接入；另建目标时需要完整依赖，不能只拷贝 `LabModel.swift`。源码入口为 [LabModel](../../Apps/TransportLab/Sources/LabModel.swift)、[窗口消息](../../Apps/TransportLab/Sources/WindowSession.swift)、[连接偏好](../../Apps/TransportLab/Sources/ConnectionPreferences.swift)。

1. App 生命周期持有一个 `LabModel`，视图观察该实例；沿用 `LabApp` 的一次性 `WebRTCRuntime.initialize()`。调用模型方法及更新 UI 在主线程进行，不为每个页面创建连接。
2. 读取 `ConnectionPreferences.profile`，检查 `validationError`；调用 `profile.apply(to: model)`，再 `model.connect()`。`ConnectionProfile` 的默认桥接是 `.socket`，裸 `LabModel` 的默认是 `.network`，所以不能省掉 profile 应用后假定与基线相同。
3. 等待 `windowSupported`。收到首次支持窗口协议的 offer 后模型会自动请求目录；界面手动刷新调用 `refreshRemoteWindows()`。`catalogLoading` 或 `windowBusy` 期间禁止重复事务。
4. 将本次目录中的 `RemoteWindow` 原对象传给 `selectRemoteWindow(window)`。目录刷新会更换句柄；不持久保存旧 `id`，不使用标题或窗口编号自行拼造选择消息。
5. `windowBusy` 时显示切换状态。`selectedRemoteWindow` 非空只表示选择事务已确认；`track` 非空也不证明已经出帧。待本代 `sample.framesDecoded > 0` 才进入可观看状态。
6. 使用 `ColorManagedVideo(track: track)` 承载 SDR / HDR，由稳定的 `MobileViewport` 或客户端容器包裹。调整布局、显示设置页、缩放或平移时保持同一 track 的 renderer 存活；换 track 或退出时走已有解绑和队列清理。
7. `selectRemoteWindow(nil)` 停止观看、保留认证信令，可以继续选窗；`stop()` 才是断开整个连接。停止观看不会关闭 Mac 的窗口。
8. 使用 `windowError` 展示选窗/目录错误，`error` 展示连接错误。目录超时为 10 秒，选窗事务超时为 20 秒；后者会断开连接。`unavailable` 会停止媒体但保留连接，允许改选。

`running` 表示连接生命周期已启动，不是“视频已连接”。`windowSupported` 表示目录能力，不是控制授权。`RemoteWindow.widthPoints / heightPoints` 是目录时的逻辑尺寸，`sample.width / height` 是实际视频像素；两者都不等于正式输入所需的几何版本。

状态栏只展示当前有效样本；切换窗口时计数会清零，不跨媒体代次求帧率。码率、fps、codec、PQ 附件读 `sample`，不能把 Viewer 的发送预设 1080p / 25 Mbps 当作收到的视频参数。`selectedRemoteWindow == nil` 时，连接初始仍可能先显示 Host 的固定测试窗口，不应伪造已选择的目录项。

## 呈现与生命周期边界

现有 [HDRVideoView](../../Apps/TransportLab/Sources/HDRVideoView.swift) 使用色彩管理的原生像素缓冲和 `AVSampleBufferDisplayLayer`，每视图保留一个待提交帧。真实观看不改成截图轮询、JPEG 或逐帧 `UIImage`，避免丢失 HDR 元数据并增加复制。渲染器和遥测仍由通信侧维护；iOS 外层可以独立调整布局。

当前 `LabApp` 在进入后台时调用 `stop()`；前台恢复要重新连接并取得新目录句柄，不复用旧窗口事务或旧输入。是否增加有限自动重连由 iOS 生命周期设计决定，当前没有无限自动重连能力。设置页不会主动断开视频，真实后台与 App 内页面切换要区分。

Host 的 `realtime` 是发送端 RTP 提示。Viewer 报告中自己的 `playout=adaptive` 不等于 Host 提示失效。pacing / playout 初始化是进程级，不能在 UI 中反复初始化或只通过重连修改 Host 策略。接收 UI 不应借修改本地 `resolution` / `megabits` 假装调整远端编码；正式质量/resize 协商尚未提供。

## WPS 原型迁移与后续接口

iOS 侧已有真实 WPS 编辑原型，见[其记录](../testing/iPhone-WPS真实桌面投流.md)。它使用独立 H.264 媒体和仅本机 `127.0.0.1:48274` 的认证 HTTP 控制，入口仅编入模拟器；不能直接当作已支持异地 iPhone 的正式控制协议，也不要把该调试端口开放到 Ponte 来绕过接入工作。

保留原型的视口、键盘、手势和 AX 执行经验，下一项需要双方共同接通：

| 接口增量 | 通信 / Host 需提供 | iOS 消费方式 |
|---|---|---|
| 控制能力与租约 | 控制能力声明、授权/撤销、目标及到期状态、断线释放 | 能力可用才开放控制；否则真实观看仍可使用 |
| 目标几何 | 内容矩形、逻辑尺寸、像素倍率、几何版本、媒体代次和对应首帧 | 用确认后的同一映射绘制与命中；变更期间暂停输入 |
| 点击/拖拽/滚动 | 版本化消息、序号、目标检查、按下/抬起/释放与 Host 实际执行 | 复用既有手势输出；过期目标不发送 |
| 文本提交 | commit ID 去重、目标/焦点检查、实际执行确认/失败 | 本地完成 IME 组合后提交；确认前不显示已写入远端 |
| resize | 请求、Host 接受的实际尺寸、新媒体首帧确认或拒绝原因 | 复用已有布局意图，不能把请求尺寸当作实际结果 |

以上是下一步工作边界，不新增本轮 wire message，也不把尚未实现的方法写成可调用 API。需要这些接口时在通信会话列出具体阻塞即可；无需重开整套媒体路线比较。

## 文件和设备交接

- iOS 可继续修改客户端布局、`IOSLabView`、`RemoteWindowsView`、`ConnectionPreferences` 和 `MobileInteraction`；通信核心按本基线收敛，必要接口变化单列。
- `LabModel`、工程、版本和签名是共享文件。使用独立 DerivedData，合并工作区差异后再生成工程；不要用旧 Git HEAD 覆盖当前工作区。当前有效代码含未提交和未跟踪文件。
- 原 USB 真机由 iOS 研发使用。通信侧不再发起 devicectl、镜像、UI 自动化、基准、安装或显示模式调整；已完成的定时测试不再续跑。
- Mac 普通 Host 继续服务原配置，只接受一个观看者。iOS 开发者可在手机里断开旧连接后用自己的客户端连接，不必更改配对码或启动第二个同端口 Host。
- 首轮接入由 iOS 侧安排：连接 → 目录 → 实际窗口 → 本地缩放/横竖屏 → A/B 选窗 → 停止/重选 → 后台/前台重连。当前通信会话不代为执行这些真机操作。
- 出现无法连接、无画面、HDR 错色或换窗串流等接入阻塞时，提供构建/源快照、操作序列、实际格式和 `exportReport()`；普通体验默认不开逐帧诊断。

虚拟机接入时，使用 `.build/handoff/transport-v1-ios-20261114.tar.gz` 的源码参考快照和 `MANIFEST.json` 校验各文件。压缩包必须解到独立目录，再选择合并通信文件；客户端文件仅作集成参考，不覆盖 iOS 会话已有实现。包内不含本地签名、连接凭据、私有日志、应用二进制或 WebRTC 下载缓存；依赖版本仍固定为 157.0.0。该快照不是 Git 提交或已签名发布。

看板以 W02 的真实窗口接入为下一项；T03 / T04 / T06 / T07 的保留问题暂停排期，状态和历史失败证据保留。后续先服务产品接入，不继续用长测挤占真机。
