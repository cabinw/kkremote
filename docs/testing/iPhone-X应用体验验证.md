# iPhone：使用真实 X 网页应用验证窗口与输入

日期：2026-11-13。用户确认的对象是 Chrome 网页应用 X.app（入口 x.com），不是原生 Twitter.app。

> 本页原有测试记录属于上一版工具栏 UI。最新原生外观与输入验证见 [原生外观改版验证](iPhone原生外观改版验证.md)。

## 测试方式

使用独立的 ego-browser 标签页加载真实 `https://x.com/explore`。iPhone 模拟器上的独立客户端验证包，复用实际客户端的窗口外壳、触摸状态机、视口几何及系统中文输入组件，通过一个临时本地适配器交换浏览器画面与测试事件。

这不是仿制 X 页面，也不是通过正在测试的 KKRemote Host 捕获原 X.app 进程。浏览器测试源只验证目标窗口体验，不能据此认定现有 Host 已实现自动 resize、输入注入或低延迟串流。

适配器仅监听 `127.0.0.1` 的随机端口，以每次启动生成的 token 校验请求。没有使用 Host 的端口、配置或协议；没有复制浏览器 cookie。未操作真机、未启动或停止正在测试的 Host。

## 完成的改进

- **窗口比例**：按 iPhone 可用工作区生成逻辑尺寸提议，旋转时重新布局；可切换到 1280×800 桌面比例作对照。只有对应画面尺寸得到确认后才采用它映射触摸；调整中暂停输入，忽略旧尺寸的迟到画面。
- **像素密度**：从浏览器合成器读取高密度画面，按实际 PNG 尺寸声明密度。最终竖屏样本为 402×657 逻辑点、1206×1971 像素。输入坐标始终使用逻辑点，避免 Retina 的倍数偏移。
- **单指滚动**：iPhone 直接触摸模式可单指滑动滚动；长按拖拽仍独立。单指转双指先结束滚动，再判定捏合，避免滚动与缩放串扰。预览滚动每 100 ms 合并发送，并合并队列中等待的滚动事件。
- **键盘避让**：键盘出现不重新调整 X 窗口尺寸，也不将画面强制复位缩小；保留缩放与可见内容位置，并根据已确认的搜索框位置将其移入可见区域。
- **中文输入**：系统输入法负责组词；选定候选词后一次提交。文本使用提交 ID 去重；未确认的提交保留重试入口。后台、退出和切换目标清理未提交组词。

单指滚动策略也启用了 iPhone 离线工作区。真实客户端的视口复用“保留缩放与焦点可见”组件；真实 Host 输入仍保持只读，未暗中接通到浏览器适配器。

## 验收结果

| 检查 | 结果 | 证据 |
|---|---|---|
| 真实 X 窗口比例、桌面比例对照、横竖屏、单指滚动 | 通过；除画面序号外，还断言真实页面 scrollY 增大 | `.build/ios-x-preview/x-acceptance.xcresult` |
| 真实 X 中文输入 | 通过；nihao 组词时禁止发送，候选“你好”进入 X 搜索框一次，键盘不改变源窗口尺寸 | 同上 |
| 原有 iPhone 工作区回归 | 4 / 4 通过 | `.build/ios-x-preview/x-final.xcresult` 中 IPhoneWorkspaceTests |
| 触摸、几何、IME 等原生组件 | 19 / 19 通过，含新增 5 项 | `.build/ios-x-preview/native.xcresult` |
| 主工程 iOS Simulator 构建 | 通过 | `.build/ios-x-preview/production-final.log` |
| macOS 条件编译与纯组件 typecheck | 通过 | `swiftc -typecheck Apps/TransportLab/Sources/MobileInteraction/*.swift` |

X 输入测试没有按回车提交搜索；结束后清空了搜索框。没有发布、点赞、关注或发送私信。适配器仅允许搜索框点击与输入、滚动、尺寸调整和刷新；其他点击不会派发给页面。

截图：

- [适配 iPhone 比例](../../.build/ios-x-preview/final-evidence/x-iphone-adaptive.png)
- [桌面原比例对照](../../.build/ios-x-preview/final-evidence/x-iphone-desktop-ratio.png)
- [横屏](../../.build/ios-x-preview/final-evidence/x-iphone-landscape.png)
- [系统中文候选词提交至真实 X 搜索框](../../.build/ios-x-preview/final-evidence/x-real-chinese-keyboard.png)

## 复现

1. 在仓库根目录执行 `scripts/run-ios-x-preview.sh`。需要安装 ego-browser，并能在独立浏览器任务中访问 X 的搜索页。
2. 等待 `.build/ios-x-preview/bridge.json` 出现。它包含本次临时端口和 token，不应提交到仓库。
3. 使用 `Apps/IOSInteractionLab/client-project.yml` 生成独立验证工程，在 iPhone Simulator 上执行 `ClientIntegrationTests/XExperienceTests`。该测试仅在适配器配置存在时运行，平时跳过。
4. 如需手动体验，将配置中的 `url`、`token` 作为 `--x-preview-url`、`--x-preview-token` 启动参数传给模拟器的 `com.cabinw.kkremote.clientreview.simulator`。这些入口只在模拟器编译。
5. 停止适配器时，对配置中本次 `pid` 发送 SIGTERM；它会清空测试搜索框、删除临时配置并结束自己的浏览器任务。SIGUSR2 用于开发期间重载适配器，保留同一个浏览器任务。

## 限制与下一步

这是截图与事件适配器，不是视频媒体管线；刷新频率和操作耗时不能作为产品帧率或延迟数据。X 原有桌面布局仍可能保留侧栏、卡片横向滚动等页面自身行为。没有裁剪或篡改页面伪装成原生移动版。

还需要在允许 Host 联调后，把同样的尺寸确认、焦点几何和输入提交约束接入真实窗口服务与媒体流，再验收真正的 Casement 类桌面投流体验。
