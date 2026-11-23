# iPhone 正式链路界面接入（2026-11-14，构建 22）

当前 Excel 完整显示和独立 Host 自动尺寸联调见 [iPhone Excel 窗口自适应](iPhone-Excel窗口自适应.md)。以下为颜色和既有链路的验证记录。

## 圆角外侧背景统一（构建 29）

用户指出窗口圆角仍有白色漏出。工作区背景不足以保证 UIKit 场景和根视图的底色一致；另外，HEVC 画面不含透明通道，Mac 采集边角中的浅色已经成为视频像素。修正包含：

- 根 SwiftUI 背景覆盖所有安全区，`WindowSceneBackground` 只更新所属 UIWindow 及其根控制器背景，使用同一份取色值；不使用全局 appearance。
- 所选 Mac 窗口在源窗口坐标中按 20 点连续圆角裁切，让圆角之外透明地露出根背景；不向正文叠加颜色。
- 移除工作区单独的背景颜色动画，避免它与根背景更新不同步。

构建 27 的竖屏截图中，背景 RGB 为 231，左上视频角 `(1,177)` 为 251，右上为 246；构建 28 统一根背景和初步裁切后，外角已为 231，但圆角内缘仍有亮边，因此继续调整边界。截图与只读 Core Image 像素检查保存在 `.build/ios-corner-review`。

构建 29 真机回归 51.445 秒通过。截图上背景与上边缘外侧角点均为 RGB 231（同一 sRGB 读取方法），旧版外角 RGB 246–251 的漏白消失。证据：`.build/ios-corner-review/corner29.xcresult`、`evidence29/`、`pixels29.log`。应用自身圆角内的细边框保留，未改变正文颜色或 Host。

## 当前实现：纯色背景和桌面显示

用户确认整屏灰感出现在 iPhone 实际屏幕，并要求顶部直接设置 App 背景色。构建 21 已移除额外顶部视频图层，仅用 SwiftUI Color 设置背景；不在视频上叠颜色。取色输出使用 extended sRGB，与桌面显示的参考白点保持一致。P010 小色块仅留作显式测试启动的只读亮度诊断，正常使用不创建、不显示。

发灰对照：构建 18 关闭顶部视频图层后取得真实 Agentail 视频，窗口背景采样 Y=569（P010，PQ），实际 EDR headroom≈2.90；故不能仅归因于顶部图层或无 HDR 余量。显式启用 HDR 动态范围以及单独禁用层 tone mapping 均未在设备预览中消除灰感，不能声称它们已解决问题。构建 18 对照结果留在 `.build/ios-device-review/color18.xcresult`。

客户端新增“画面显示：桌面 / HDR”，默认桌面。桌面模式将收到的 PQ 帧经 Core Image 转为带正确 sRGB 标签的 BGRA8 显示副本，以 203 nit 参考白点显示普通桌面；extended sRGB 输出避免普通 bounded sRGB 的隐式 HDR 白色压缩。超出桌面范围的 HDR 高光会裁切，需完整高光时选择 HDR 原始显示。Host、编码协商和接收到的 Main10/PQ 不变，不能把输入仍为 PQ 描述为桌面模式仍输出 HDR。

转换仅在有显示提交机会时执行，复用最多 8 张输出缓冲；原始帧保持不变。原始 HDR 模式及 macOS 原显示路径不经过转换。`Tests/DesktopVideoColorTests.swift` 验证 7 组 ST 2084 亮度锚点、灰阶中性色、输出标签、SDR 直通、源帧不变、池上限和释放后恢复。普通 SDR 视频不作转换。

构建 21 的完整观看流程通过，但颜色专项测试出现 16 次转换缓冲不足，不能标为整体通过。构建 22 将有限池容量由 4 调整到 8，移除取色的强制 HDR 压缩后，颜色专项真机测试 19.972 秒通过，显示失败为 0；7 组 PQ 锚点和 180 帧原 HDR 渲染回归通过。证据 `.build/ios-device-review/color22.xcresult`。

以下构建 16 及更早章节为历史记录，不代表当前仍使用顶部视频色块。

## 顶部仍偏白的修正

用户反馈构建 14 的顶部仍显白。复查确认上一轮仅检查取色成功不足以证明融合效果：窗口上沿细边框干扰采样，且将 PQ 视频颜色转换为 SDR 后再填充，与实际视频呈现存在亮度差。构建 15 仅将采样移到可见窗口内部，仍未消除分界，不作为最终修复。

构建 16 保留 SDR 主色估计以过滤文字和选择状态栏字色，但 HDR 填充改用主色对应的原始 P010 像素，生成 32×32 均匀色块，保持 Y/UV、PQ/BT.2020 及亮度附件，复用原视频的 AVSampleBufferDisplayLayer 路径。取色仍为最多 2 Hz、单帧在途；不修改主视频、Host 或连接配置。切换 track 会清除旧色块，代次检查拒绝旧回调。非 P010 视频继续使用原有 SDR 填色。

`Tests/NativeWindowSwatchTests.swift` 通过 10134 项原始像素断言，覆盖不同行跨度、色度分量、坐标钳制、源帧不变、附件保留及不支持格式回退。可使用 swiftc 联合编译 `WindowEdgeColor.swift` 执行。

构建 16 Release 编译成功；真机完整流程 69.542 秒、0 失败，新增断言确认 PQ 视频已生成原生色块。证据为 `.build/ios-device-review/lan-viewer16.xcresult`、`lan-evidence-16/` 和 `native-swatch-tests.log`。正常版本安装使用原局域网配置，Host 保持原进程。

## 最新状态：局域网构建 14

用户确认 iPhone 与 Mac 在同一 Wi-Fi，要求先做 LAN，Ponte / Tailscale 留到后续。本节取代下文构建 13 的阻塞状态；失败记录作为历史保留。

- 手机保存地址改为当前 Mac 局域网地址，标签 LAN；45990 / 45991、配对码、fixed-udp-v2 / socket 保持。允许 iOS 本地网络访问后接通。现有 Host PID 86689 未重启或覆盖。
- 主工程 Release 构建 14 成功并安装。25 项原生组件测试、2115 项视口几何断言通过。
- 真机完整流程通过，68.380 秒、0 失败：真实 WPS、HEVC Main10 PQ 2560×1440、边缘取色、铺满/完整、悬浮按钮拖动、捏合平移、横竖屏布局、A/B 切窗、前后台新目录恢复、停止重选。
- 前台立即重连曾撞上 Host 的 1 秒重新监听间隔。客户端增加可取消的 1.5 秒等待、最多一次尝试后通过；测试确认恢复使用新的目录句柄。等待首帧时保持渲染器挂载但隐藏未就绪画面，显示原生进度提示。
- 正常版本启动不带测试参数或诊断倒计时。XCUITest 仅用于研发验证。
- PQ 视频已产生稳定灰色顶部填充；安全区仍为 SDR，不声称与 HDR 高光亮度完全一致。导出的 HDR 截图可能偏白；横屏截图存在旋转捕获异常，布局断言不能替代视觉检查。
- 随后在 Device Hub 中复查正常构建 14 的真实 WPS 横屏画面，未见测试截图中的大片黑区；已恢复竖屏和默认自动铺满，保留 WPS 供用户体验。实际画面为远端视频，未使用本地示意页面。
- 本轮为真实观看体验验收。自动铺满是本地缩放/裁切，未改变远端 WPS 尺寸。正式远端点击、中文回传、resize 仍未接入，不能把本地手势或文档中以前的“已验证”字样当作本轮输入成功。

证据：`.build/ios-device-review/lan-viewer14.xcresult`、`lan-viewer14.log`、`lan-evidence-14/`、`production14.log`。历史失败结果保留，本轮不再展开隧道测试。

## 范围和授权

用户在通信协议研发会话明确将真机交给 iOS 研发，要求接入现有 HDR/Ponte 链路；通信侧继续暂停测试。此授权取代之前仅限模拟器的限制。沿用本机保存的 Ponte 主机、信令 45990、媒体 45991 和原配对配置，不在公开文档中记录实际地址或配对码。

接入前核对现有普通 Host PID 86689 仍存活，45990 监听属于该进程；二进制仍是 `.build/PonteFreeze/Build/Products/Release/KKRemoteLabMac.app`。没有重启、重编译覆盖或另起同端口 Host。

## 本次代码

- 正式 `IOSLabView` 使用默认自动铺满的本地视口，保留“显示完整窗口”；悬浮选窗与工具菜单可拖动，不占固定底栏。
- 保留 `ColorManagedVideo` 和原生 HDR 渲染。按照当前 Host 明确的 aspect-fit、左上原点画布规则，用窗口目录尺寸去除已知编码留边。目录尺寸仅用于显示，不授权输入；桌面窗口随后被外部调整时需刷新并重选，下一版需正式几何版本契约。
- `WindowColorSampler` 为只读观察器，最多 2 Hz、单帧在途、64×4 边缘采样；Core Image 依据帧色彩信息将取色副本映射为 sRGB。原始视频帧和 HDR 元数据不修改。依据可见视口上沿更新采样区；主色桶过滤文字图标，重复确认和平滑过渡避免闪烁，状态栏按亮度选择字色。
- 采样器绑定到当前 track，移除旧观察器并用代次过滤晚到回调。模拟器 WPS 原型也复用同一采样器。
- 有解码首帧后才能操作观看视口。停止观看调用 `selectRemoteWindow(nil)`，保留连接。后台先停止连接；返回前台最多尝试一次重连，重新取得目录后匹配窗口身份并传递新的目录对象，绝不发送旧 handle。失败保留手动重连入口。
- 正式链路不提供键盘/远端触摸模式按钮。本地手势仅改变显示，远端点击、中文文本确认和 AX resize 仍是下一轮协议工作。

## 验证结果及当前阻塞

- 主工程 Release 构建 13 编译成功，USB 安装到 iPhone 15 Pro Max；25 项原生组件测试通过。
- 真机自动化是研发阶段的 XCUITest，独立运行器不属于客户端正常使用链路。启动只加 `--viewer-ui-review`（只读、无凭据的测试状态），没有媒体诊断倒计时。
- 首轮真机测试在连接等待处失败，尚未取得窗口目录或视频帧，**不能算 HDR、选窗、切换、缩放或前后台恢复验收通过**。
- 手机保留的连接配置已核对：原 host/端口、`fixed-udp-v2`、`socket`。手机 Surge 对 `mbp-home.sgponte:45990` 的记录显示 `DEVICE:MBP-HOME`、`Ping timeout`，收发均 0 B。Host 日志没有收到本轮新会话。
- 用户确认 Mac 换了 Wi-Fi。Mac Surge 当时仍运行；检查与刷新设备列表后再次手动连接仍握手超时。没有调整 Surge 全局配置、重置配对码或切换至其他地址。
- 顶部颜色在此前模拟器 SDR WPS 验证通过；本次 **HDR 真机颜色匹配仍未验证**。安全区是 SDR 填色，不能声称与 HDR 高光亮度完全一致。

本地产物：`.build/ios-device-review/viewer13-provisioned.xcresult`（失败证据）、`integration-status.json`、`native-components.log`、`final-build13.log`。包含本地连接配置的文件留在忽略目录，不放入仓库。

## 通道恢复后的验证

使用 `Apps/IOSInteractionLab/device-project.yml` 生成独立测试工程到 `.build/ios-device-review`。固定目标为 iPhone 15 Pro Max，其他真机不参与。测试用 WPS 测试文档和既有 `KKRemote Repeatable Load Fixture` 窗口验证：连接、目录、Main10 PQ 首帧、铺满/完整、捏合与平移、旋转、A/B 切换、前后台新目录恢复、停止重选。任一环节未实际通过须继续标为待验。

Core Image 取色副本的 SDR 映射依据：[Apple toneMapHDRtoSDR](https://developer.apple.com/documentation/coreimage/ciimageoption/tonemaphdrtosdr)。这不改变视频渲染路径。


## 构建 31：独立 Host 触摸接通

2026-11-14 已在独立 LAN Host 上接通 Excel 单击、单指滚动和确认后中文回传，并安装到已授权真机。测试与限制见 [iPhone-Excel触摸与中文回传](iPhone-Excel触摸与中文回传.md)。原正式通信 Host 保持原样。
