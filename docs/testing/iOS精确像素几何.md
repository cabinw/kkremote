# iOS 精确像素几何

2026-11-15。客户端配合源端偶数像素窗口尺寸，只修改显示/命中几何与对应测试。本客户端实现与模拟器验证阶段未安装或启动 USB 真机应用，未操作 Host、显示器、HDR helper 或系统服务；后续真机联合验收由通信会话完成，结果见下文。

## 条件与行为

`ViewportGeometry` 接收可选的实际解码 `encodedPixels` 和 SwiftUI `displayScale`。只在 zoom=1、非 fill、非键盘宽度裁剪、正的偶数编码尺寸、画布可落入视口、每轴空隙小于 2 物理像素、编码与确认源点尺寸等比例时启用 `pixelExact`。数值容差为 1e-6 物理像素，用于浮点误差，不容许源尺寸差一行或一列。

430×873 pt @3、源窗口 645×1309 pt、视频 1290×2618 px 时，内容尺寸为 430×872⅔ pt，偏移为 (0,0)，剩余一行留在底部。两侧不分摊半个像素；该余量不参与触摸命中。横屏 2442×1290 px 按相同规则显示。源点、编码像素和屏幕点始终分别计算。

`MobileViewport` 的渲染与 `MobileInteractionSession` 的触摸映射共用 `makeGeometry`。生产视频通过 `geometryContent` 得到同一几何，精确模式直接使用其内容尺寸，跳过原编码画布的再次适配。边缘取色继续读取会话几何，并在解码尺寸改变时刷新。旧源、比例不符、尺寸过大或留白较大、旋转旧帧、缩放、fill、键盘模式沿用现有布局。

验收字段在 `viewerState`：`pixelExact`、`displayScale`、`contentPixelWidth`、`contentPixelHeight`、`contentPixelX`、`contentPixelY`。这些字段描述客户端几何；实际 AV 图层像素遥测由通信会话负责，不能以几何字段代替真机图层测量。

## 验证

- `bash scripts/test-ios-viewport.sh`：2,403 项断言通过，含竖/横屏、单像素余量、源点映射、旧源和过渡回退、缩放锚点。
- iPhone 17 Pro 模拟器原生组件：33 项通过。新测试检查实际 UIKit 视图 bounds×3 为 1290×2618、渲染几何与输入一致、键盘模式退出后恢复、解码尺寸更新时 renderer 不重建。
- 完整 `KKRemoteLab` Release iOS Simulator 构建通过；独立 DerivedData `.build/iOSPixelAlignmentClient`。
- 结果 `.build/ios-pixel-alignment/native.xcresult`，日志 `native.log`、`client-build.log`。

生产文件：`ViewportGeometry.swift`、`MobileInteractionSession.swift`、`MobileViewport.swift`、`IOSLabView.swift`。测试：`Tests/ViewportGeometryTests.swift`、`Apps/IOSInteractionLab/NativeTests/MobileInteractionTests.swift`。无 wire 字段变更。

## 构建 42 联合真机验收

通信会话完成 iPhone 15 Pro Max / USB 构建 42 验收，本会话已核对其[专项报告](精确像素与窗口恢复验证.md)及[交接记录](../design/iOS真实体验接入交接.md)。Chrome 与 Excel 竖屏为 1290×2618，横屏为 2442×1290；六个检查点覆盖影片、横竖屏往返、双向切窗、断开重连，客户端 `pixelExact` 和实际 AV 图层 `displayOneToOne` 均为 true，显示失败为 0。证据为 `.build/pixel-exact/motion-final.xcresult`。这补足了模拟器几何检查之外的实际显示层验证，消除了本轮发现的末次适配缩放。

源窗口进入与退出工作区、宽窗口恢复由通信会话修复并验证；iOS 继续消费确认后的源几何，不另写窗口恢复逻辑。真实影片操作使用客户端既有远端输入通道，本轮没有为 Chrome 或 Excel 增加产品输入特例。

主动真机测试已结束，设备恢复无诊断参数普通启动。原地址、端口、配对不变，Host 保持监听；当前 Host 指针为 `.build/iphone-resume-20261114/ready-host.json`，helper 状态为 `.build/pixel-exact/workspace.json`。旧 `.build/hdr-workspace/workspace.json` 仅作历史记录，不再作为运行入口。未更新 TestFlight。

像素一对一不等于通用原生字号或无损画质：本轮测试内容仍用了源应用 150% 缩放；通用内容字号、色度损失、长期冻结和私有显示 API 产品化均未完成。通信、采集与编解码问题继续交给通信会话，iOS 侧负责布局、触摸和输入体验。
