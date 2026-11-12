# TestFlight 与传输实验

更新：2026-11-12。本文保留 KKRemote Lab 0.1.0 **构建 2** 的能力、分发与首次审核记录；以下“本版”均指构建 2。仓库后续已加入固定 UDP 适配器、H.264 能力修正、复杂画面与双 Mac 测试，当前实现和测试命令以 [Ponte 固定 UDP 实验](Ponte固定UDP实验.md) 为准。新适配器尚未随构建 2 分发。

Lab 的目的是建立可反复安装、连通和测量的实验入口；窗口产品仍按 v0.3 架构推进。

## 1. 已实现与待验证

| 能力 | 当前状态 |
|---|---|
| Mac 发送源、Mac / iPad / iPhone 接收端 | 已有原生应用工程；当前发送合成动态画面 |
| 认证信令 | Network.framework TLS 1.2 PSK；每次启动主机生成 256 位随机配对密钥 |
| 媒体与控制 | 原生 libwebrtc M157，H.264 SDR，DTLS-SRTP 视频与 DataChannel ping/pong |
| 视频参数 | 720p / 1080p / 1440p，30 / 60 fps，8–120 Mbps **上限**；不是固定目标码率 |
| 统计与导出 | RTP 有效载荷码率、像素、帧率、控制 RTT/P95、ICE RTT、丢包/NACK、候选类型；本地 JSON |
| 本机回环 | 两个真实 WebRTC peer，720p30；供安装检查、回归与 Beta 审核 |
| Tailscale / Ponte | 可填写对应端点；实际媒体连通性与路径需要两端测试，尚未验收 |
| 窗口捕获、触控、键鼠、音频 | 未实现 |
| HEVC / Main10 / HDR / EDR | 未实现；H.264 基线不替代这些技术关口 |

没有云端账号服务、STUN/TURN 服务或自动遥测。信令支持一个接收端。主机被停止或配对失败后需要重新启动；配对密钥随之更新。iOS 进入后台会停止会话，返回前台后手动重连。

## 2. 环境与构建

- 本次已验证：Xcode 27.2、macOS 27.2.1、XcodeGen 2.46.0；iPadOS 26.5 模拟器。
- 工程最低部署版本：macOS 15、iOS / iPadOS 18。最低版本设备尚未实测。
- Swift Package 固定 `stasel/WebRTC` **157.0.0**，锁文件随工程提交。它是社区 XCFramework 分发，不是 Google 官方发布的 Apple 二进制。
- 依赖 ZIP 的 SwiftPM SHA-256：`ffb1221be2138ecc6bc92300ae4f0157e18694d652db9921e4251992ea91a328`。第三方许可随 App 打包。
- `project.yml` 是工程配置来源。脚本每次构建会运行 XcodeGen；修改工程设置后应同步该文件。

```bash
brew install xcodegen
scripts/build-lab.sh mac
scripts/build-lab.sh simulator
scripts/test-signaling.sh
```

Mac 运行位置：`.build/DerivedData/Build/Products/Debug/KKRemoteLabMac.app`。Mac 脚本使用本地 ad-hoc 签名，不生成可供其他 Mac 下载安装的公证包。

命令行连通性回归：

```bash
.build/DerivedData/Build/Products/Debug/KKRemoteLabMac.app/Contents/MacOS/KKRemoteLabMac --self-test
```

通过条件：35 秒内至少收到 60 帧解码视频，并收到 DataChannel 的 ping/pong 回应。该测试同时经过 TLS 信令、ICE、H.264 编解码和控制消息路径，但不验证真实网络性能或画面最终扫描显示时间。

`test-signaling.sh` 使用真实本机 TLS 连接验证正确配对、错误密钥拒绝、跨读取块的多帧消息还原，以及超长消息拒绝。

## 3. 开发者账号与上传

本机 Xcode 使用已登录的开发者账号自动管理签名。不要在仓库中存储密码、API 私钥、证书私钥、描述文件或测试账号。

首次配置：

```bash
cp Config/Signing.example.xcconfig Config/Signing.local.xcconfig
cp Config/ExportOptions.example.plist Config/ExportOptions.local.plist
```

将两个本地文件中的 `YOUR_TEAM_ID` 替换为自己的开发团队 ID。两者已被 `.gitignore` 排除。目标 Bundle ID 分别为 `com.cabinw.kkremote.lab` 与 `com.cabinw.kkremote.lab.mac`；其他团队使用时应先修改 `project.yml` 中的 Bundle ID。

每次上传必须递增构建号，示例：

```bash
BUILD_NUMBER=3 scripts/build-lab.sh archive
scripts/upload-testflight.sh
```

归档在 `.build/KKRemoteLab.xcarchive`。上传使用 `app-store-connect`。本轮起导出配置启用 `testFlightInternalTestingOnly=true`，将后续构建限制为内部测试；历史构建 2 即使未使用 internal-only，也可以直接用于内部测试而无需 Beta 审核。上传成功仅表示文件被接收；还需等待 Apple 处理，检查邮件及 TestFlight 中的最终构建状态。

本次构建 1 已上传，但 Apple 后续处理以 `ITMS-90683` 拒绝：SDK 引用摄像头 API，需要用途说明。构建 2 已补充摄像头和麦克风用途说明，明确当前实验不会启用这些设备，并于 2026-11-12 通过 Apple 上传后的处理检查。不要为了通过检查虚构采集功能。

已知非阻断警告：上游 XCFramework 包不含 WebRTC 的 dSYM，上传可能提示 `Upload Symbols Failed`。App 自身有调试符号；WebRTC 内部崩溃的符号化仍受影响。正式稳定性阶段应补齐与该二进制 UUID 对应的符号，或采用可复现的源码构建。

## 4. TestFlight 内部测试流程

应用：[KKRemote Lab 的 TestFlight 后台](https://appstoreconnect.apple.com/apps/6833924397/testflight)。该链接供开发者管理，并不是测试员安装邀请。

本项目当前仅做团队内部测试，**不需要 Beta App Review**。使用另一个 Apple 账号或异地 iPad 并不意味着必须外部测试；关键是该账号是否为有此 App 访问权的 App Store Connect 用户。

1. 在“用户和访问”中邀请指定测试账号，授予支持内部测试的职能并仅选择 KKRemote Lab。当前使用“营销”职能，不授予管理、财务、创建 App 或签名资源权限。
2. 测试员先用自己的 Apple 账号接受团队邀请，再加入 `Development` 内部测试群组。
3. 上传后等待 Apple 完成构建处理，并按实际加密实现填写问卷。Network.framework 信令使用系统 TLS；WebRTC 包含自身的标准 DTLS/SRTP 实现，不能笼统申报为“仅使用 Apple 系统加密”。
4. 将“准备测试”的构建加入内部群组，向该组测试员发出 TestFlight 邀请。无需提交外部 Beta 审核，也无需重新上传已经处理完毕的构建。
5. 测试员在 iPad / iPhone 上安装 Apple TestFlight，接受 TestFlight 邀请并安装 KKRemote Lab。团队邀请和 TestFlight 邀请是两个步骤。

截至 2026-11-13：0.1.0（2）已加入 `Development` 内部群组；指定账号已接受团队邀请并作为内部测试员加入，后台显示“已邀请”。构建显示“准备测试”，用户已确认异地 iPhone 安装成功，当前尚未核实远端 iPad 实际安装。该账号已从原外部群组移除，外部群组没有测试员；此前的外部审核不再是本轮测试的前置条件。构建 2 不含后续固定 UDP v2、socket 调度与性能观测修改，测试这些功能需上传新构建。

历史记录：11 月 12 日曾把另一 Apple 账号当作外部测试员，建立 `Remote iPad Transport Lab` 群组并提交构建 2 的 Beta 审核；11 月 13 日按用户要求改为上述内部测试流程。联系人和测试员的私人信息不写入仓库。

构建 3 已于 2026-11-13 完成签名归档与上传，使用 internal-only 分发，包含固定 UDP v1/v2、可选 socket 传输与本轮诊断。Apple 已完成处理；加密问卷按标准算法、此次不在法国分发填写完毕。构建 3 已加入 `Development` 内部组，后台显示“正在测试”，可由现有内部测试员更新；异地 iPhone 媒体连通性仍待实际连接验证。

## 5. 第一轮远程连接

Mac 端：

1. 启动 Lab，先设为 1920×1080、60 fps、25 Mbps 上限。
2. 使用默认信令端口 `45990`，点击“启动 Mac 测试源”。
3. 通过已有可信渠道把主机端点及本次完整配对码提供给接收端。只交给参与测试的设备，停止主机即结束本次会话。

iPad / iPhone / 另一台 Mac：

1. 确认对应覆盖网已连接。填写可达的 Mac IP 或主机名、端口及完整配对码。
2. 网络标签选 Tailscale 或 Surge Ponte。它只标注实验，**不会强制 ICE 使用指定接口**。
3. 点击“连接主机”，确认视频出现、解码帧数增长、控制 RTT 更新。
4. 持续运行 3–5 分钟，点击“生成测试报告”，再“分享 JSON”；发送端也导出一份，以比较发送和接收指标。

**Tailscale：**优先从 Mac 的 Tailscale 地址开始。WebRTC 必须收集并选择覆盖网可达的 UDP 候选；只有信令 TCP 可达还不够。需结合 Tailscale 自身诊断记录外层 direct / relay，Lab 的 `host/udp` 不能证明外层直连。两端不在同一个 LAN 的测试才能排除走本地网络的假阳性。

**Surge Ponte：**`name.sgponte:45990` 能连接只验证了信令入口。本基线使用自动 ICE 候选和动态 UDP 媒体端口，没有做 Ponte 候选映射、固定媒体端口或自定义 socket 适配。如果出现“信令已通，ICE 失败”，应记录为适配缺口，而不是反复提高码率。后续按 [传输路线复核](../design/传输路线复核.md) 的 Ponte 关口决定端口/候选适配或 QUIC 对照。

不要据此开放公网端口。本轮假设两端已经通过 LAN、Tailscale 或 Ponte 建立受控可达性。

## 6. 报告应如何解释

| 字段 | 含义与限制 |
|---|---|
| `videoMbps` | 相邻统计样本的 RTP 视频 payload 字节差；不含全部协议、重传和外层 VPN 开销，首个样本为 0 |
| `width/height/fps` | 编码或解码统计中的实际数值，不是 UI 预设 |
| `controlRTTMilliseconds` | DataChannel 同端单调时钟测得的往返；包含调度与处理，不等于单向或输入到显示延迟 |
| `controlP95Milliseconds` | 最近最多 120 个成功回应的 P95；超时未响应的 probe 不计入，因此不能独立代表总体可用性 |
| `networkRTTMilliseconds` | ICE 候选对报告的 RTT，可能缺失或短时为 0 |
| `candidatePair` | ICE 候选类型及协议，不含地址，不反映覆盖网内部直连/中继 |
| `preset` | 本机配置；接收端不能用它修改主机，分析发送预设应看主机报告 |
| `encoder/decoder` | SDK 报告的实现名；未提供时为 unknown，不自行推断硬件路径 |

报告保留最多 3600 个每秒样本，时间为会话相对时间；没有配对密钥、SDP、端点地址、窗口内容或用户输入。只有点击分享后，报告才通过所选渠道离开设备。用户主动分享前可检查 JSON。

目前合成移动网格容易压缩，设置 80 或 120 Mbps 上限不表示实际就会产生相应负载。**本版适合验证连接、视频、控制与安装链路，不足以给出高码率容量结论。** 下一版需要加入可控复杂度画面/媒体回放，结合真实窗口内容测试，并记录编码耗时、发送队列、解码队列、帧呈现与丢帧原因。不要把填充流量冒充画质改善。

## 7. 下一步协议验收顺序

1. **真机连通性**：Mac → iPad，分别验证 LAN、Tailscale 跨网和 Ponte 跨网；记录两端设备、OS、App 构建号及覆盖网路径，成功标准是实际视频和控制均通。
2. **路径控制**：补齐候选/端口诊断与必要的 Ponte 适配，避免同 LAN 绕过覆盖网导致假阳性。到期望路径可复现后再比较性能。
3. **高码率阶梯**：固定内容、分辨率、设备与网络，按 20/45/80/120 Mbps 上限递进；报告实际码率、稳定帧率和排队，不把配置数值当结果。
4. **低延迟与恢复**：补齐采集到呈现时间链路或光学测量；验证丢包、抖动、突发拥塞、后台返回、Wi-Fi 切换后的恢复。当前控制 RTT 只作诊断辅助。
5. **HEVC/HDR 关口**：验证原生 VideoToolbox 接入、完整颜色元数据与渲染，再决定保留 libwebrtc、定制内部模块或实现 QUIC 对照。此时才适合对协议路线做最终取舍。
6. **窗口闭环**：加入 ScreenCaptureKit 单窗口、几何版本和控制租约，之后再优化移动端留白、边框、手势和布局。

## 8. 官方与上游依据

- [Apple：添加内部测试员](https://developer.apple.com/help/app-store-connect/test-a-beta-version/add-internal-testers)
- [Apple：邀请外部测试员](https://developer.apple.com/help/app-store-connect/test-a-beta-version/invite-external-testers)
- [Apple：提供测试信息](https://developer.apple.com/help/app-store-connect/test-a-beta-version/provide-test-information)
- [Apple：加密文档要求](https://developer.apple.com/help/app-store-connect/reference/app-information/export-compliance-documentation-for-encryption/)
- [Apple TN3213：Network.framework PSK 的 TLS 版本限制](https://developer.apple.com/documentation/technotes/tn3213-moving-from-multipeer-connectivity-to-network-framework)
- [WebRTC Apple 二进制包与许可证](https://github.com/stasel/WebRTC/tree/157.0.0)

TLS-PSK 仅用于当前实验的短期认证信令，不具备该套件层面的前向保密，也不是未来长期设备身份方案。正式配对会采用可撤销的设备身份、密钥更新与会话绑定。
