# iPhone 窗口体验验证

> 本文保留上一版窗口外壳的历史验证。当前 UI 已改为内容铺满与悬浮菜单，最新结果见 [原生外观改版验证](iPhone原生外观改版验证.md)。

日期：2026-11-13。范围：iPhone 优先的窗口工作区、离线触摸和中文输入。设计与真实能力边界见 [iPhone 窗口体验](../design/iPhone窗口体验.md)。

## 环境与隔离

- UI：iPhone 17 Pro / iOS 26.5 Simulator。
- 原生组件回归：已有 iPad Pro 11-inch / iOS 26.5 Simulator，仅跑共享组件测试，没有扩展 iPad 界面设计。
- 独立客户端验证包：`com.cabinw.kkremote.clientreview.simulator`，包含实际客户端源码与独立配置。
- 未连接 Host、未修改 Host / 协议 / 编解码文件、未安装或启动真机应用。

## 用例

1. 实际客户端：退出预览后仍未连接；远端输入按钮禁用；连接设置与详细数据可打开返回；首页不再显示测试指标卡片。
2. 窗口工作区：竖屏画面超过屏幕高度 65%（17 Pro 实测约 75%）；点击勾选正确命中；捏合、复位、触控板切换；横屏、切换窗口、回到竖屏。
3. 中文：真实拼音键盘输入 nihao，组词中禁止发送，点候选“你好”后只提交一次；输入 zhong 尚未选词就换窗口，新窗口没有旧草稿，原窗口保留已发送内容。
4. 横屏输入：画面高度大于 50 点、输入结果区域与视口相交；输入框、发送、收起入口可访问；后台再回来清空未提交拼音；取消输入恢复窗口标题栏。
5. 原有共享练习：点击、长按拖拽、缩放与真实中文候选词输入继续可用。
6. 原生组件：14 项状态机、取消释放、只读保护、IME、Unicode、渲染视图生命周期测试。

## 本轮发现并修复

- 离线预览和底层首页有重复辅助功能节点：改为未连接时独立进入预览，避免同时挂载两个工作区。
- 窗口列表行只有文字图标可点：整行设置明确的点击区域。
- 横屏键盘占据工作区：收起标题栏与提示文字，使用紧凑编辑栏。
- 示例文档在小高度下压缩和偏移不正确：保持内容自然高度，按实际输入区域测量位置，并明确顶部对齐。
- 取消 / 系统收键盘后保留空编辑栏：焦点结束时收起编辑栏。
- 自动化在旋转和回到前台时过早点击：等待横屏控件几何与可点击状态，不添加固定睡眠。

## 可复现入口

```sh
xcodegen generate --spec Apps/IOSInteractionLab/client-project.yml --project .build/ios-client-review
xcodebuild -project .build/ios-client-review/KKRemoteClientReview.xcodeproj \
  -scheme KKRemoteClientReview \
  -destination 'platform=iOS Simulator,id=D4B1A386-60E4-4268-A691-2C38E278D540' \
  -derivedDataPath .build/ios-client-review/DerivedData \
  -clonedSourcePackagesDirPath .build/SourcePackages \
  -parallel-testing-enabled NO -jobs 2 test
```

在未连接的模拟器客户端首页点击“体验 iPhone 离线预览”，或启动时传入 `--iphone-workspace-review`。

## 不在验收结论内

没有用这些离线结果证明真实 Mac 应用可以窄屏重排、Host 窗口 resize 生效、远端键鼠或中文注入生效，也没有测量真实链路延迟和视频性能。大字体辅助功能、其他 iPhone 尺寸及第三方键盘还需要专项验证。

## 结果与证据

本轮按改动范围分批回归，最终相关用例均通过：

| 检查 | 结果 | 本地证据 |
|---|---|---|
| 中文提交、换窗口草稿隔离；竖横屏、点击、缩放、切换 | 2 / 2 通过 | `.build/iphone-workspace/portrait-final.xcresult` |
| 横屏键盘、内容可见、后台清理、取消恢复 | 1 / 1 通过 | `.build/iphone-workspace/landscape-aligned.xcresult` |
| 实际客户端只读控件与设置、原有共享练习 | 两项通过 | `phone-verified.xcresult` 中对应的两个用例；该历史批次的旧横屏断言失败已由上面的最终结果替代，不能把整个历史批次当作通过 |
| 共享原生组件 | 14 / 14 通过 | `.build/iphone-workspace/native-regression.xcresult` |
| 主工程 KKRemoteLab / iOS Simulator | BUILD SUCCEEDED | `.build/iphone-workspace/production-complete.log` |
| macOS 条件编译排除与纯组件 typecheck | 通过 | `xcrun swiftc -typecheck Apps/TransportLab/Sources/MobileInteraction/*.swift` |

截图：

- [竖屏窗口与已提交中文](../../.build/iphone-workspace/iphone-preview.png)
- [中文键盘](../../.build/iphone-workspace/iphone-chinese-keyboard.png)
- [横屏输入可见区域](../../.build/iphone-workspace/landscape-final-evidence/BFB99FE0-02E6-4AC5-91CE-DB61C9AE7953.png)

截图和 xcresult 放在被忽略的 `.build` 中，清理构建目录后需重新生成。早期失败结果保留用于定位，不代表最终验收状态。
