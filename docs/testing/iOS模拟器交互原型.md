# iOS 模拟器交互原型

日期：2026-11-13。用户允许在真机通信测试期间，使用模拟器研发客户端交互。

## 实现与隔离

新增独立 `Apps/IOSInteractionLab`，App 名称「KKRemote 交互原型」，bundle ID 为 `com.cabinw.kkremote.interaction.simulator`。只使用本地 SwiftUI 示例窗口和 UIKit 手势，不包含 WebRTC 或网络连接。编译时禁止真机目标。

XcodeGen 工程和 DerivedData 写入 `.build/ios-interaction/`；使用 2 个编译任务，按设备依次运行 UI 测试。未修改主工程、版本、签名、连接配置、LabModel、媒体核心；未安装真机、连接或重启 Host、提交 Git 或发布 TestFlight。已有未提交改动保留。

完成固定窗口视口基础：保持完整比例，统一显示与触点映射，黑边不命中，缩放范围 1–4 倍，平移限制在有效范围。提供直接点击 / 长按位置、触控板指针和原生文字输入的本地预览。切换模拟窗口清理草稿及坐标，视口尺寸变化复位缩放与平移。

## 验证结果

| 检查 | 结果与范围 |
| --- | --- |
| 几何测试 | 2,115 项断言通过；包括横竖比例、多种视口、缩放 / 平移往返、黑边、无效尺寸、缩放锚点 |
| iPhone 17 Pro / iOS 26.5 模拟器 | 4 组 UI 测试通过，0 失败 |
| iPad Pro 11-inch (M5) / iOS 26.5 模拟器 | 同样 4 组 UI 测试通过，0 失败 |
| 旋转补充检查 | 两种设备横屏后可点击画面、工具按钮可用；窗口切换及旋转复位通过 |
| 构建 | 独立模拟器 App 及 UI 测试目标编译通过 |

四组 UI 用例：

1. 居中点击映射到源窗口中心；点击留白不产生源坐标。
2. 切换触控板模式、打开原生键盘、输入英文和数字、提交至本地预览；换窗后输入框关闭。
3. 捏合放大、恢复完整显示、长按右键位置预览、相对指针移动。
4. 按钮放大 / 复位、从横向浏览器切到纵向文档、旋转后复位并点击。

首轮 UI 测试发现固定源尺寸撑大了手势接收区域，已将手势视图及容器明确限定到可见视口。自动注入的点击存在屏幕坐标量化，UI 测试对源中心允许 2 个逻辑点误差；纯几何往返检查误差小于 1e-6。

## 证据及复现

运行说明见 [原型 README](../../Apps/IOSInteractionLab/README.md)。几何测试入口为 `bash scripts/test-ios-viewport.sh`。

本地证据保存在忽略目录：

- `.build/ios-interaction/iphone-final.xcresult`：iPhone 四组通过记录。
- `.build/ios-interaction/ipad-final.xcresult`：iPad 四组通过记录。
- `.build/ios-interaction/rotation-final.xcresult`：补充横屏交互检查。
- `.build/ios-interaction/rotation-screen.xcresult` 和 `ipad-screen.xcresult`：整屏截图及旋转回归通过。
- `.build/ios-interaction/iphone-evidence/` 与 `ipad-evidence/`：原始附件及 manifest。

横屏 `XCUIApplication.screenshot()` 的截取区域出现黑色留白及裁切，与可点击的横屏坐标状态不一致，截图辅助函数已改用 `XCUIScreen.main.screenshot()`。多 destination 运行下 iPad 附件仍有截取异常，独立运行 iPad 后获得完整横屏截图并通过交互检查。不能用有裁切的旧截图作为最终外观证据。

已目视复核的最终截图：`.build/ios-interaction/iphone-portrait-document.png`、`iphone-landscape-document.png`、`ipad-portrait-document.png`、`ipad-landscape-document.png`。纵向固定窗口在横屏完整显示时会留下侧边空白，这是当前固定几何模式的预期表现；远端窗口主动适配比例尚待 Host 支持。

## 尚未覆盖

- 真正的桌面窗口自动 resize、几何版本与媒体首帧切换。
- 远端点击、滚动、拖拽、输入租约与按键释放；当前事件仅本地预览。
- 中文拼音候选选择、组合取消、删除和远端焦点切换的完整输入流程。
- iPad 分屏 / 多窗口、外接键鼠、辅助大字体、深浅色矩阵和后台恢复专项。
- 双指平移已有实现及几何边界断言，尚无独立多触点 UI 平移回归。
- 视频 renderer 生命周期、真实投流、HDR、触控延迟、蜂窝性能及真机手感。

本轮是 M01 / M02 / M03 的离线基础原型，不将这些任务或移动产品阶段标记完成；也不替代 U01 的最终外观审核。
