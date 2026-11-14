# iPhone 原生外观改版验证

2026-11-13。根据“UI 不通过，要更像原生 APP”的反馈，本轮替换上一版窗口标题和四按钮工具栏。仅使用模拟器与独立浏览器测试源，未操作真机或正在测试的 Host。

## 体验变化

- 主界面以应用内容为主体，填满安全区域。只保留一个 44 pt 悬浮工具菜单，进入编辑时隐藏。连接设置、窗口切换和诊断仍可从菜单进入。
- X 使用真实 x.com 的移动页面布局，自身搜索栏和底部导航直接呈现。通过移动 viewport 与 user agent 选择页面布局，没有改写页面 CSS 或裁掉桌面侧栏。
- 点击实际搜索框，在其已确认的源窗口位置覆盖原生 UITextView，立即弹出 iOS 系统键盘。没有第二个输入栏、发送按钮或重复的“完成”工具条。
- 系统输入法保留未确认拼音，确认候选词后自动同步完整字段值；删除同步，避免每次追加造成重复。同步合并等待 120 ms，失败保留重试，提交 ID 去重。
- 键盘出现时保留源窗口尺寸与显示缩放，移动视口使焦点可见。“完成”只收起键盘，不向 X 发搜索回车。
- 直接触摸不显示鼠标十字；相对触控板模式保留指针。

原生外壳已接入实际 iPhone 客户端。X 原位输入属于模拟器隔离适配器验证；正式客户端的 Host 输入仍禁用。离线示例没有远端输入框几何，继续保留显式提交作为回退。

## 测试与证据

| 检查 | 结果 | 证据 |
|---|---|---|
| 原生组件（手势、几何、IME、候选确认与删除同步） | 21 / 21 通过 | `.build/ios-native/native-components.xcresult` |
| 工作区（菜单、只读边界、窗口切换、后台取消） | 4 / 4 通过 | `.build/ios-native/native-final-v2.xcresult` 的 IPhoneWorkspaceTests |
| 真实 X（比例切换、横竖屏、单指滚动、原位中文、删除、完成收起） | 2 / 2 通过 | `.build/ios-native/native-x-final.xcresult` |
| 主工程 iOS Simulator 构建 | 通过 | `.build/ios-native/main-final-build.log` |
| 条件编译、适配器语法、diff 空白检查 | 通过 | swiftc typecheck、node --check、git diff --check |

最终选定的 27 项检查均通过。过程中发现并修正了工具菜单自动化在前台恢复动画前点击、测试残留搜索值、初始化误打开搜索建议层等问题。`native-final-v2` 中早期 X 滚动失败保留作过程记录，由 `native-x-final` 的通过结果替代。

截图：

- [新版主界面](../../.build/ios-native/final-evidence/x-native-app.png)
- [原位中文与系统键盘](../../.build/ios-native/final-evidence/x-native-inline-chinese.png)
- [横屏](../../.build/ios-native/final-evidence/x-iphone-landscape.png)
- [桌面比例对照](../../.build/ios-native/final-evidence/x-iphone-desktop-ratio.png)

测试未按回车提交搜索，没有发布、点赞、关注或私信操作。结束后清空测试搜索框并关闭独立浏览器适配器。

## 复现与范围

沿用 [X 应用体验验证](iPhone-X应用体验验证.md) 的独立工程与启动流程。XExperienceTests 每次测试先重置本任务的独立 Explore 页面，防止上次失败残留文字或滚动位置影响下一次测试；不清理 cookie、账户设置或其他标签页。

移动网页适配不代表任意 Mac 桌面应用可以在客户端重新排版。本轮没有采集原 X.app 进程，也没有验证 Host resize、真实视频流延迟或正式远端输入。后续需在允许 Host 联调后接入窗口尺寸回执、输入框焦点几何与输入协议。

界面截图供用户复核；功能检查通过不代表用户已接受这版 UI。
