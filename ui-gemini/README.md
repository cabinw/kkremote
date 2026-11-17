# KKRemote 移动端界面交互设计方案 v2（ui-gemini · Liquid Glass & 物理单窗优先）

> **定位**：面向 **iPhone / iPad** 的窗口优先（Window-First）原生远程操控界面与交互设计规范（**v2 全面重构优化版**）。  
> **目标**：先完整达到 **Casement 移动端核心操控体验**（窗口化沉浸、Dock 启动、原生菜单栏投影、自适应尺寸、双模指针、辅助快捷键与软件键盘、剪贴板/音频桥接），再结合 **iOS 27 / iPhone Duo 液态玻璃（Liquid Glass）竖排侧边交互** 与 **KKRemote 物理单窗零干扰捕获 + 10-bit PQ HDR 原生像素链路**，实现视觉质感与单手可达性的跨越升级。  
> **范围约束**：本文档集为纯界面与交互方案设计，**不包含任何产品代码实现**；方案严格对齐仓库现有接口契约（`LabModel`、`ColorManagedVideo`、`MobileInteraction` 与 [contracts.md](../docs/design/contracts.md)），并严格遵循**默认物理窗口捕获、不启用虚拟显示器或自动打乱本机窗口排布**的宿主偏好。

---

## 零、v2 重新优化的核心升级点（Design Evolution v2）

1. **全端统一的「内容感知 Liquid Glass 液态玻璃系统」**：
   - 彻底告别 v1 中 iPhone 悬浮胶囊/快控盘/抽屉偏厚重黑底的割裂感；iPhone 与 iPad 共享同一套基于 `oklab` 感知混色的双态玻璃令牌——底层为浅色文档（WPS / Safari）时自动切换为**亮霜白玻璃（Frosted Daylight Glass）**，底层为深色应用（VS Code Dark EDR）时平滑切换为**深邃曜石玻璃（Smoked Obsidian Glass）**，所有图标统一升级为 `1.75px` 线性矢量符号。
2. **双端「Duo 右侧竖排侧边胶囊」与底部胶囊自由切换**：
   - 借鉴 **iPhone Duo（iOS 27）右侧竖排侧边按钮**，不仅 iPad 默认采用右侧三组悬浮 Liquid Glass 胶囊轨，**iPhone 同样支持一键将控制胶囊切换至「右侧竖排 Duo 侧边态」（横屏默认启用、竖屏按需一键切换）或收拢为右缘 6pt 灵动微拉手**，100% 释放表格底部 Sheet 标签栏与社交应用底栏。
3. **物理单窗本机零干扰默认策略（Physical-Window Non-Disruptive Default）**：
   - 默认直采 Mac 本机物理窗口，**不创建虚拟屏、不强制自动改乱本机桌面窗口尺寸**；iPhone 端支持在胶囊与快控盘**一键秒切「可读铺满 1:1」↔「完整窗口全貌（P010 原生取色衬底）」**；iPad 端默认整屏完整呈窗、滑动直接滚动桌面内部内容，仅在用户主动点击「对齐画布」时按需请求尺寸适配。
4. **Control-Center 风格 Bento 快控盘与 MenuBar 置顶磁贴**：
   - 快控盘重构为紧凑 Bento 磁贴网格，面板高度缩减约 30%；MenuBar 顶部新增 4 宫格高频命令磁贴（如 `保存 ⌘S`、`撤销 ⌘Z`、`冻结首行`、`导出 PDF`），单拇指一次点按直达。
5. **空间化连接主页与多桌面空间可视化启动台**：
   - 主页主卡片内置活跃物理窗口微缩快切条（1 步直达目标窗口）；启动台新增 macOS `Spaces` 桌面空间筛选芯片与高辨识度窗口骨架缩略图。

---

## 一、核心设计原则

1. **内容即应用，外壳退隐（Content is the App）**
   - 桌面应用画面从状态栏下方铺满到屏幕底边，取消常驻标题栏、状态横幅和固定底部工具栏；应用本身占据 95%+ 的可交互面积。
   - 顶部与侧边安全区自动融合远端窗口可见边缘的原生色彩（延续并强化现有 `WindowEdgeAppearance` + `NativeWindowSwatch` 的 P010 HDR/SDR 融合链路），保证状态栏反色可读、无割裂灰白边。
2. **手势直觉优先，零层级焦虑（Zero-Menu Friction）**
   - 任何高频切换（直触 ↔ 拇指触控板、视口平移 ↔ 操控、键鼠/剪贴板/菜单速搜、快速换窗）都必须在 **1 次点击或单手连续手势** 内完成，彻底消除“打开菜单 → 切换模式 → 操作 → 再打开菜单切回”的 4 步折返。
3. **诚实几何与安全输入（Honest Geometry & Safe Input）**
   - 严格区分**本地视口观察变换**（捏合缩放、双指平移、边缘快窥）与**远端窗口逻辑尺寸事务**（`ResizeRequest` → `ResizeResult` → 新 `streamEpoch` 首帧确认）。
   - 未获控制租约、目标窗口有歧义、最小化、断流或尺寸切换中，界面诚实呈现当前状态并进入只读或暂停态，绝不向错误布局或旧画面注入盲目点击，绝不残留粘滞按键。
4. **原生像素与 HDR 透明可控（True Retina & HDR Transparency）**
   - 不隐式锁死低倍率缩放（如 Casement 静态分析中观测到的 tablet 1.5× / 6 Mbps、handheld 2.0× / 4 Mbps 策略上限），允许用户以直观的语义档位查看和选择真实像素密度、10-bit PQ HDR 状态与延迟代价。
5. **物理手感与单手可达（Ergonomic Reach & Tactile Feedback）**
   - 针对 6.1"–6.9" 大屏手机顶部难以触及的现实，引入**单手拇指触控区（Thumb-Zone Trackpad）**、**边缘微放大镜（Precision Loupe）**、**手势触觉语法（Haptic Grammar）** 与 **胶囊边沿快捷手势**。

---

## 二、对标 Casement 与优化创新总矩阵

基于对本机 `Casement Home 1.0.4`（[casement.md](../docs/research/casement.md)）及公开产品能力（`casement.win`）的分析，下表明确定义“**先做到**”与“**优化和创新**”的完整边界：

| 体验维度 | 先做到：Casement 移动端核心体验 | KKRemote 优化与创新点 | 对应设计章节 |
|---|---|---|---|
| **窗口发现与启动** | 枚举桌面运行中窗口 + 读取 Mac Dock / 已安装应用列表，支持一键唤醒/启动桌面应用；提供整屏回退入口 | **双轨极速启动台（Window & Dock Deck）**：合并“实时/近期缩略图卡片 + 状态徽章（运行中/最小化/其他空间）+ 常驻 Dock 横条 + 全局模糊搜索”；卡片左滑直达关闭/隐藏；头部预留 `hostID` 切换器适配未来多主机 | [01 信息架构与流转](./01-information-architecture-and-flows.md) |
| **沉浸外观与边框** | 独立窗口铺屏呈现，去除传统远程桌面的桌面壁纸与多窗口杂乱 | **HDR 原生边缘无界融合 + 动态胶囊避让**：不仅融合 SDR 主色，更直接用原生 P010 色块匹配 HDR 视频亮度阶，胶囊自动半透明静默并磁性吸附四角/侧边，避免遮挡桌面应用角落关键按钮 | [02 iPhone 界面蓝图](./02-iphone-interface-and-adaptive-viewport.md) |
| **小屏窗口适配** | 请求 Mac 调整窗口逻辑尺寸以匹配移动容器（`ResizeRequest`），无法缩小则保持桌面比例并允许缩放 | **三段式智能视口引擎**：① 可缩应用 1:1 移动化；② 最小宽度受限应用（如 WPS 672pt）默认**智能锚点铺满**（保留行号/主栏），**无需切出操控即可随时双指平移/缩放**；③ **按住胶囊边沿触发「微缩地图快窥（Overview Peek）」**，松手或点击缩略图某区域一键跳转视角 | [02 iPhone 界面蓝图](./02-iphone-interface-and-adaptive-viewport.md) |
| **触控与指针操控** | 直接触控 + 软件触控板双模式；独立 `CursorUpdate` 光标（形状/热点/显隐）；Mac 滚动与追踪曲线适配 | **混合操控革命**：① **按住浮窗展开扇形快控盘（Quick-Deck）** 一步切换；② **底部拇指触控垫（Thumb Trackpad Drawer）** 解决单手点不到 Mac 顶部红绿灯/工具栏的痛点；③ **指尖偏移放大镜（Offset Loupe）** 在直触模式下精准命中 10pt 小按钮；④ **触觉反馈语法**让 0.4s 右键/拖锁/边界吸附有明确手感 | [03 触控与手势系统](./03-touch-trackpad-and-gesture-system.md) |
| **Mac 菜单栏交互** | 通过 Host AX 读取当前应用顶部菜单树（含勾选状态、禁用态、快捷键提示）并在客户端投影唤起 | **MenuBar 树 + 命令速搜（Command Palette）+ 高频动作钉选**：输入关键词（如“导出/冻结/Split”）跨层级直达菜单命令，并按 `bundleID` 自动记忆/钉选该应用高频 4 个动作 | [04 键盘 IME 与菜单栏](./04-keyboard-ime-and-menubar.md) |
| **键盘与中文输入** | 系统键盘文本输入 + 独立修饰键辅助条（`Esc`/`Tab`/`⌘`/`⌥`/`⌃`/`⇧`/方向键）+ 可选完整 60% 桌面软键盘 | **双轨中文 IME + 情景快捷键条**：① Host 返回焦点框时**原位透明覆盖 `UITextView`**，无焦点框时弹出贴合键盘顶部的**灵动输入条（带目标坐标徽章如 `WPS · C8` 与一键 Tab/回车跳转）**，候选态严格本地隔离防重字；② 快捷键条按应用类型（表格/浏览器/终端/通用）自动切换预设，支持单击预备与双击锁定修饰键 | [04 键盘 IME 与菜单栏](./04-keyboard-ime-and-menubar.md) |
| **画质与链路感知** | 8-bit SDR HEVC + 静默图块无损恢复（settle）；端侧隐藏实际 scale 与码率上限 | **Retina 2×/3× 与 10-bit PQ HDR 原生直出**：取消隐式 1.5× 降采样，在菜单胶囊顶部提供一句话语义画质档位（原画 HDR / 锐利文字 / 省流）与轻量级实测摘要；详细遥测收敛至二级「诊断面板」，不污染主画布 | [02](./02-iphone-interface-and-adaptive-viewport.md) / [06](./06-protocol-gap-and-design-tokens.md) |
| **剪贴板与音频** | 双向文本剪贴板同步 + 应用音频实时串流 | **情景化剪贴板微提示条（Smart Clipboard Chip）**：仅当检测到新剪贴板内容时在输入框/胶囊旁浮现 1 秒可点芯片「粘贴来自 iPhone / 发送至 Mac」，兼顾隐私与效率；音频独立静音开关集成于胶囊与菜单 | [04 键盘 IME 与菜单栏](./04-keyboard-ime-and-menubar.md) |
| **iPad 与外设体验** | 原生多窗口（Split View / Stage Manager 并排）+ 硬件键鼠 + Pencil | **iPad 右侧悬浮 Liquid Glass 侧边轨（参考 iPhone Duo 竖排按钮）+ 整屏呈窗 + 快捷键路由开关**：半透明分组胶囊悬浮右缘让 Mac 窗口 100% 满宽呈窗、滑动仅滚动桌面内容、清晰指示 `⌘Tab` / `⌘Space` 发往 iPad 还是 Mac、Apple Pencil 悬停与压感映射 | [05 iPad 与外设方案](./05-ipad-and-external-peripherals.md) |

---

## 三、方案文档结构索引

| 文档 | 内容摘要 | 主要读者 |
|---|---|---|
| **[交互高保真原型](./index.html)** | 可直接在浏览器运行的高保真 HTML 交互原型（支持 iPhone 竖/横屏、iPad 侧边轨、三段悬浮胶囊拖拽、拇指触控垫、2.2× 放大镜、鸟瞰小地图、MenuBar 命令检索、双轨中文 IME 与 U01 诊断） | 全体成员 / 体验评审 |
| **[01 信息架构与流转](./01-information-architecture-and-flows.md)** | 全应用信息架构、连接配对主路径、Window & Dock 启动台、全生命周期与异常状态机、Lab 诊断隔离边界 | 产品、iOS、通信 |
| **[02 iPhone 界面蓝图与视口](./02-iphone-interface-and-adaptive-viewport.md)** | iPhone 竖屏/横屏高保真线框图（含 pt 尺寸）、灵动胶囊与扇形快控盘、三段式视口引擎、缩略图快窥、HDR 安全区融合 | 产品、设计、iOS |
| **[03 触控、触控板与手势系统](./03-touch-trackpad-and-gesture-system.md)** | 直接触控 / 完整触控板 / 拇指垫 / 视口平移仲裁矩阵、指尖放大镜、独立光标渲染、触觉反馈语法、防卡键保护 | iOS、Mac Host |
| **[04 键盘、中文 IME 与菜单栏](./04-keyboard-ime-and-menubar.md)** | 双轨中文输入与防重防丢状态机、情景快捷键条、修饰键粘滞逻辑、60% Mac 软键盘、MenuBar 命令速搜、剪贴板/音频 | iOS、Mac Host |
| **[05 iPad 工作区与外设适配](./05-ipad-and-external-peripherals.md)** | iPad 多窗与分屏、右侧悬浮 Liquid Glass 侧边轨（参考 iPhone Duo）、整屏呈窗与内部滚动、外接键鼠、Apple Pencil、多主机 UI 预留 | iOS、产品 |
| **[06 设计规范、协议缺口与验收](./06-protocol-gap-and-design-tokens.md)** | 视觉 Design Tokens（字体/材质/对比度/动效）、UI 对 Host/协议的增量需求清单、优雅降级策略与可用性验收指标 | 全体研发 |

---

## 四、与工程现状及既有文档的衔接

- **可直接复用的现有基线**（据 [iOS真实体验接入交接.md](../docs/design/iOS真实体验接入交接.md) 与 [iOS交互组件与输入边界.md](../docs/design/iOS交互组件与输入边界.md)）：
  - 媒体渲染与色彩：`LabModel`、`ColorManagedVideo`、`WindowEdgeColor` / `NativeWindowSwatch`。
  - 几何与手势底座：`ViewportGeometry`、`InteractionGestureMachine`、`MobileTouchSurface`、`MobileInteractionSession`、`MobileWindowSizing`。
  - 中文输入基座：`MobileTextSession` / `MobileTextEditor`（`markedTextRange` 隔离、revision 失效机制、提交去重 ID）。
  - 界面原型参考：`IPhoneWindowWorkspace`（可拖动胶囊与沉浸底边）、`WPSWorkspace`（真实桌面最小宽度下的自动铺满与键盘避让）、`IPhoneXPreview`（`InputFocus` 原位覆盖输入）。
- **本方案不破坏的既有约定**：
  - 保留「测试/连接基线」与「详尽统计/导出 JSON」在诊断 sheet 的可访问性，不因产品化包装而隐藏 `U01` 所需的研发验证指标。
  - 明确标注每一项依赖远端 Host 控制协议（`W01`–`W07`）的能力在只读阶段如何**诚实降级**，保证当前只读观看构建（构建 16 基线）也可立即落地视觉壳层与本地视口交互升级。
