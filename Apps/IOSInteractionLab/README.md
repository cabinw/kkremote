# iOS 离线交互原型

此目录是 KKRemote 客户端视口的独立研发入口。原型仅支持 iOS Simulator，以独立 bundle ID 安装，不连接 Host、不创建网络会话、不依赖 WebRTC。共享组件已移至 `Apps/TransportLab/Sources/MobileInteraction/`，原型与 iOS 客户端编译同一份代码。

## 本轮范围

- 三种固定逻辑尺寸的本地示例窗口，完整显示并保留四边和标题栏。
- 同一几何模型完成绘制、触点映射、黑边排除、1–4 倍缩放及平移约束。
- 直接点击、静止长按右键、长按后拖拽、双指滚动、触控板相对指针；进入平移模式后拖动画面。一次接触选择滚动或缩放后锁定意图，避免混发。
- 原生 UITextView 跟踪中文候选组合，组合期间禁止发送；确认后显式发送一次。支持多行、选择替换和 Unicode 删除；取消、换窗、后台及系统键盘收起会清理草稿。
- 旋转、可用尺寸变化和键盘避让引起视口变化时复位本地变换，不发出远端 resize。

这是功能原型，事件仅进入本地示例，不接入窗口 resize、Host 输入注入或控制租约。原生中文候选流程已有模拟器 UI 测试，仍不代表远端文字输入端到端通过。当前本地尺寸变化会复位缩放；以后结合 Host 焦点矩形和版本化几何完善焦点保持。

## 构建和验证

在仓库根目录执行：

```sh
bash scripts/test-ios-viewport.sh
xcodegen generate --spec Apps/IOSInteractionLab/project.yml --project .build/ios-interaction
xcrun simctl list devices available
```

选择一个模拟器 UDID 后执行（不要填真机 UDID）：

```sh
xcodebuild -project .build/ios-interaction/KKRemoteInteraction.xcodeproj \
  -scheme KKRemoteInteraction -configuration Debug \
  -destination 'platform=iOS Simulator,id=<模拟器 UDID>' \
  -derivedDataPath .build/ios-interaction/DerivedData \
  -parallel-testing-enabled NO -jobs 2 test
```

生成的 App 名为「KKRemote 交互原型」，bundle ID 为 `com.cabinw.kkremote.interaction.simulator`。不要用本原型覆盖 `KKRemote Lab`。

## 客户端接入和验证

`IOSLabView` 的观看页已使用 `MobileViewport` 包裹原有 `ColorManagedVideo`，支持本地捏合、平移及完整显示。默认会话是只读的，不能产生输入事件。模拟器「设置 → 离线交互练习」复用相同的手势和文字组件，进入本地事件预览。

`client-project.yml` 使用完整客户端源码建立独立模拟器包 `com.cabinw.kkremote.clientreview.simulator`，不载入真实配对配置；`ClientTests` 通过 `--offline-interaction-review` 打开练习页，验证触摸和中文输入后检查客户端仍未连接。构建与测试命令同上，把 spec 改为 `client-project.yml`，project / scheme 改为 `KKRemoteClientReview`，并使用独立 DerivedData。

## 接口边界

`ViewportGeometry` 用于固定窗口视口；实际远端输入必须使用明确的捕获内容矩形、窗口逻辑坐标及几何版本，不能把统计面板里的宽高直接用于远端输入。`InteractionGestureMachine` 产生手势意图，`MobileInteractionSession` 管理本地坐标、缩放、指针及释放；未来网络适配器还需关联窗口、媒体代次、控制租约和输入取消。

`InteractionWorkspace` 是可抛弃的演示壳。示例数据不写入 `LabModel`，HDR 视频提交核心保持原实现。Host 动态尺寸和输入尚未实现，当前远端连接仍只有观看能力。

## iPhone 窗口工作区预览

独立客户端验证工程 `client-project.yml` 已接入 iPhone 窗口外壳。启动参数
`--iphone-workspace-review` 直接进入两个本地示例窗口，可测试切换、捏合、触控板和中文输入。
也可以在未连接的 iPhone 首页点击“体验 iPhone 离线预览”。此入口仅模拟器可用，运行中的连接不能进入预览。

`ClientTests/IPhoneWorkspaceTests.swift` 验证画面占比、横竖屏、中文草稿隔离、后台清理、只读控制和设置入口。
真实 Host 自动调整窗口尺寸和远端输入尚未接入；自适应文档只是本地 fixture。
详见 `docs/design/iPhone窗口体验.md`。

## X 网页应用体验测试

在仓库根目录运行 `scripts/run-ios-x-preview.sh` 启动隔离浏览器适配器，再执行
`ClientIntegrationTests/XExperienceTests`。测试使用真实 x.com 搜索页，只允许滚动和搜索框文字，
不连接 KKRemote Host。详情、限制和停止方法见 `docs/testing/iPhone-X应用体验验证.md`。
配置只在 `.build/ios-x-preview/bridge.json` 中短期保存，适配器未启动时 X 用例跳过。

### 原生外观改版（2026-11-13）

iPhone 工作区已改为内容铺满安全区域、单个悬浮菜单。X 隔离预览使用网页自身移动布局，并在实际搜索框位置启用系统中文编辑；候选确认与删除自动同步，不再显示底部发送框。测试每例重置本任务的独立页面。详细边界和截图见 `docs/testing/iPhone原生外观改版验证.md`。
