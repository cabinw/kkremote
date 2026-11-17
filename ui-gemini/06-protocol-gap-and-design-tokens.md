# 06 视觉设计规范、协议配合清单与体验验收标准

> 本章将前 5 章的交互蓝图落地为精确的设计系统规范（Design Tokens）、界面能力与底层协议/Host 的配合边界（含当前只读基线下的优雅降级策略），以及可度量的体验验收标准。

---

## 一、视觉设计规范（Design Tokens）

遵循 Apple Human Interface Guidelines（iOS / iPadOS）并适配 KKRemote 的 **SDR/HDR 混合显示与原生大字体（Dynamic Type）**要求：

### 1.1 材质、层级与色彩策略（v2 内容感知 Liquid Glass 令牌体系）

| 语义层级 | 材质与颜色规范（`oklab` 感知混色） | HDR / 亮暗双态自适应规则 |
|---|---|---|
| **安全区融合底层（Edge Fill）** | 复用 `WindowEdgeColor`（SDR）与 `NativeWindowSwatch`（10-bit P010 PQ 原生色块） | 仅采样当前可见视口上缘内部区域（避开 macOS 边缘亮线与圆角）；`prefersLightContent` 按线性亮度 `< 0.18` 切换状态栏与浮层明暗基调 |
| **悬浮控制胶囊 / 右侧竖排轨（Liquid Glass Rail & Pill）** | 亮霜玻璃 `color-mix(in oklab, white 80%, transparent)` ↔ 曜石玻璃 `color-mix(in oklab, #151c2c 76%, transparent)` + `blur(24px) saturate(190%)` + `1pt` 镜面顶光描边 | 随底层 Mac 窗口明暗自动切换 `tone-light` / `tone-dark`；静默 `2.5s` 自动降为 `0.58` 不透明度；激活态同时改变底色并提供 `≥ 3:1` 内描边环 |
| **Bento 快控盘 / Spotlight 菜单与诊断抽屉** | 高可读分层液态玻璃，圆角 `22–26pt`；高频操作采用 2×2 / 4 宫格 Bento 磁贴 | 正文对比度 `≥ 4.5:1`，UI 边界与选中态对比度 `≥ 3:1`；支持 `@media (forced-colors: active)` 系统高对比映射 |
| **拇指触控垫（Thumb Pad）** | 超薄透景磨砂层（`.ultraThinMaterial`），内嵌精细点阵网格与 `1pt` 触控区导引线 | 不阻断上方桌面工具栏阅读，单手 1.65× 增益直达屏幕任意死角 |
| **语义状态徽章** | 矢量图标 + 文字双通道表达：活跃直连（翠绿）、只读/协商（琥珀）、断流异常（珊瑚红）、修饰键锁存（天青） | 严禁单独依赖颜色表达状态（符合 WCAG 1.4.1），全部移除粗糙 Emoji 并统一为 `1.75px` 线性矢量图标 |

### 1.2 尺寸、热区与动效参数

- **触控热区下限**：所有独立可点击图标（胶囊分段、Side Rail 按钮、输入条关闭/提交按钮、快捷键帽）最小可响应热区 **≥ 44×44pt**（胶囊整体高度建议 `48pt`）。
- **字体排印**：
  - 界面文案全部使用系统动态字体（`.body` / `.subheadline` / `.caption`），支持 **辅助功能大字体（Accessibility Size）**；在极窄空间内允许容器滚动或换行，不强行裁切文字。
  - 所有数字遥测（帧率、码率、毫秒延迟、逻辑尺寸、单元格坐标 `WPS·C8`、快捷键 `⇧⌘S`）强制使用 **`.monospacedDigit()`**，防止实时刷新时数字跳动。
- **物理动效曲线**：
  - 胶囊吸附边缘 / Quick-Deck 展开：`spring(response: 0.32, dampingFraction: 0.82)`；
  - 边缘取色变化：`easeInOut(duration: 0.25)`（且需连续 2 次确认防压缩噪点闪烁）；
  - 窗口横竖屏切换 / 键盘聚焦滚动：`easeOut(duration: 0.22)`，确保视觉跟随流畅且不干扰输入坐标系锁定。

---

## 二、UI 能力与通信 / Mac Host 配合矩阵（协议缺口与降级策略）

> 严格对齐 [研发分工与接口边界.md](../docs/design/研发分工与接口边界.md) 与 [iOS真实体验接入交接.md](../docs/design/iOS真实体验接入交接.md)：**iOS 客户端交互先行设计，依赖远端能力的部分在缺失时必须诚实、体面降级。**

| 交互特性 | 对标层级 | 所需底层/Host 能力（及现有基础） | 当能力暂不可用时的前端降级表现 |
|---|---|---|---|
| **沉浸铺屏、顶部 HDR 取色、灵动胶囊、本地双指平移/缩放、放大镜、诊断 Sheet** | 基线 + 创新 | **100% 客户端已具备**（基于现有 `LabModel` + `ColorManagedVideo` + `WindowEdgeAppearance` + `ViewportGeometry`） | 无需等待新协议，**立即可用于当前构建 16 真实观看链路** |
| **Window & Dock 启动台（运行中窗口列表）** | Casement 基线 | **运行中列表已具备**（`WindowSession` + `RemoteWindowsView`）；缩略图、Dock 列表、应用图标、启动应用需扩展 `WindowCatalog` + `DockService` | 若仅收到基础 `RemoteWindow[]`，自动按 `application` 分组展示精简卡片，隐藏 Dock 栏不展示空骨架 |
| **自动尺寸适配（Adaptive Resize）** | Casement 基线 | 需 `W05`：`ResizeRequest` / `ResizeResult` + `streamEpoch` 首帧屏障（WPS 原型已验证本机可行） | 未接入时采用「智能锚点铺满 + 完整窗口切换」，明确标注“桌面原尺寸视图” |
| **直接触控 / 触控板 / 拇指垫 / 释放账本** | Casement 基线 + 创新 | 需 `W03/W04`：`ControlLease` + 版本化 `InputEvent` + Mac `CGEvent` / AX 注入 + `ReleaseAll` | 只读阶段胶囊隐藏键盘/触控板主切钮（仅显示「只读」徽章 + 平移/放大镜查看），杜绝无效假点击 |
| **独立高精度 Mac 光标** | Casement 基线 | 需 `W05`：`CursorUpdate`（形状 PNG + hotspot + 归一化坐标 + 显隐） | 触控板/拇指垫在无 `CursorUpdate` 时自动退回客户端本地默认矢量箭头并结合点击回传校验 |
| **原位 `UITextView` 与双轨中文 IME** | Casement 基线 + 创新 | 需 `W04`：`TextStreamEdit` 幂等提交接口；原位覆盖另需 Host AX `InputFocus` 矩形 | Host 不提供 `InputFocus` 时，自动无缝落入 **Track B 灵动草稿输入条**，保障任何 Mac 应用都能打中文 |
| **Mac 原生菜单栏投影 & 命令速搜** | Casement 基线 + 创新 | 需 Host AX 遍历推送 `MenuBar` / `MenuNode` 与接收 `MenuInvoke` | 未开启 MenuBar 接口时，面板自动退化为 **「本应用高频快捷键快捷面板」**（如保存/撤回/查找/新建标签） |
| **相关弹层（右键菜单/Sheet/Popover）自动包含** | Casement 基线 | 需 `W06`：`RelatedSurface` 或应用区域过滤裁剪同步 | 若 Host 通知当前存在未捕获弹层或超出边界，顶部弹出微提醒并支持一键切换「扩展应用区域/整屏查看」 |
| **剪贴板微芯片与独立应用音频** | Casement 基线 + 创新 | 需控制信道 `ClipboardText` 消息与 `N03` 按应用音频轨道 | 未协商时胶囊/Quick-Deck 中对应按钮显示「即将支持」或隐藏，不误导用户 |

---

## 三、移动端体验验收标准（UX Acceptance Gates）

本方案在分阶段落地（`M01–M06` / `U01–U02`）后，应按以下客观交互指标验收（与通信侧的帧率/RTT 指标互为补充）：

### 3.1 效率与可达性指标（对比旧原型 & Casement）
1. **高频操作步数**：
   - 换窗：从主工作区滑扫胶囊 `⊞` ≤ 1 步（或点击进入启动台选窗 ≤ 2 步）。
   - 查看被裁切表格右侧列 / 底部标签：直触模式下直接双指拖动或边缘内滑 **0 次切菜单**（原原型需进出菜单 4 次点击）。
   - 单手触达 Mac 窗口左上角红绿灯/工具栏：**1 次横扫唤起拇指触控垫**即可 100% 舒适拇指点击。
   - 触发常见 Mac 菜单命令：通过命令速搜 ≤ 2 次点击直达，无需钻取 4 层子菜单。
2. **屏幕利用率与视觉沉浸**：
   - iPhone 竖屏主工作区有效桌面内容占屏比 **≥ 94%**（仅扣除系统状态栏上沿与极小胶囊投影）。
   - 顶部安全区色差在 SDR 与 HDR（Main10 PQ）视频下无肉眼可见硬分界线，状态栏黑白反色 100% 可读。

### 3.2 安全性与零错乱指标
3. **手势零串扰**：
   - 连续 50 次「单指滚动 ↔ 双指缩放 ↔ 双指平移 ↔ 长按 0.4s 拖拽」交叉操作中，**0 次**因双指抬起时差产生误点，**0 次**因捏合向远端漏发滚动事件。
4. **中文输入法零重丢**：
   - 连续输入 20 组中英混排短句（含拼写中取消、候选词替换、退格删空、途中切窗/退后台），**0 次**拼音字母漏入桌面、**0 次**重复上屏。
5. **绝对无粘滞输入**：
   - 在按住 `⌘` 锁、拖拽物体过程中模拟「断网 / 切后台 / 窗口关闭 / 控制权被收回」，客户端与 Host 状态在 1 秒内全部回归释放态，**0 次卡键或卡鼠标左键**。

---

## 四、后续实施建议（面向后续开发排期）

建议按以下三步平滑推进，无需推翻现有成果：
1. **Phase 1（基于当前只读构建 16 立即可做，零协议阻塞）**：
   - 将 `IPhoneWindowWorkspace` 胶囊升级为「三段式胶囊 + Quick-Deck + 双指直接视口平移 + 边缘微指示线 + 概览微缩图快窥」；
   - 将 `RemoteWindowsView` 升级为分组 Window 启动台（预留 Dock 区）；
   - 建立「产品主模式 + 二级诊断 Sheet」的统一导航，完成 `U01` 正式审核。
2. **Phase 2（对齐 `W03/W04/W05` 控制与几何协议落地 Casement 基线体验）**：
   - 接通 `ControlLease`、版次化 `ResizeRequest`、`Direct Touch / Trackpad / Thumb Pad`、指尖放大镜、`CursorUpdate`、双轨中文 IME、辅助快捷键条与修饰键粘滞。
3. **Phase 3（打通生态闭环与差异化超越）**：
   - 接入 Host `DockService`、`MenuBarAX` + 命令速搜、智能剪贴板微芯片、应用音频、`W06` 关联弹层、iPad 多 `UIScene` 与 Side Rail / Apple Pencil 专项交互。
