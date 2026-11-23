# V1 窗口遮罩实现（五色旋转光场 + 克制随机点阵星闪）

更新日期：2026-11-13。本目录冻结并归档 `overlay-test` 第一版定稿实现，包含独立 AppKit / Metal 源码、启动脚本及本机编译产物。

> 全局说明、参考素材与跨版本历史迭代见 [../README.md](../README.md) 与 [../docs/iteration-history.md](../docs/iteration-history.md)。

## 1. 目录内容

```text
overlay-test/v1/
├── README.md                         本文：V1 方案参数、实现结构与验证记录
├── WindowOverlayProbe.swift           唯一的 Swift 源文件
├── test-window-overlay.sh             构建并运行，支持从任意工作目录调用
└── build/                            本机生成目录，Git 忽略
    ├── WindowOverlayProbe.app         当前 V1 测试 App；应通过脚本/CLI 启动
    └── legacy/WindowOverlayProbe      早期裸二进制归档，不作为运行入口
```

## 2. 状态与边界

这是一个独立的 macOS AppKit / Metal 样式探针：在任意已有应用窗口上覆盖彩色流光点阵动画，并显示毛玻璃控制条。当前只用于观察样式、跨窗口适配、窗口跟随和遮挡行为，**尚未接入 KKRemote 正式应用**。

没有视频捕获、网络连接、远程输入、控制租约或输入拦截。“远程控制中”是样式文案，同一控制条同时显示“样式预览 · 未连接远程设备”。程序不会申请辅助功能或屏幕录制权限。

当前版本采用单 pass Metal 着色器 + 改进后的控制条布局，支持通过 `--app` / `--window-id` / `--frontmost` 挂载任意应用窗口，并支持浅色/深色外观切换及任意窗口尺寸比例。

## 3. 构建与运行

### 环境

- macOS 图形登录会话，目标应用有可见窗口。
- 能通过 `xcrun swiftc` 调用的 Xcode 或 Command Line Tools。
- 仅依赖系统 AppKit、CoreGraphics、Metal、QuartzCore；无需主工程构建、Swift Package 或 npm 安装。
- 构建的是当前机器可运行的本地测试 App，不是已公证的分发包。

在项目根目录运行：

```bash
# 编译并查看帮助，不显示遮罩
./overlay-test/v1/test-window-overlay.sh --help

# 编译并列出窗口：ID、进程 ID、owner、标题、坐标
./overlay-test/v1/test-window-overlay.sh --list

# 在唯一可见的 X 或 PopAgent 主窗口上预览，默认运行 1800 秒
./overlay-test/v1/test-window-overlay.sh --app X
./overlay-test/v1/test-window-overlay.sh --app PopAgent

# 在任意多窗口应用的最前窗口上预览，或显式指定外观与圆角
./overlay-test/v1/test-window-overlay.sh --app "Google Chrome" --frontmost
./overlay-test/v1/test-window-overlay.sh --app Terminal --appearance dark

# 单独观察控制条材质、文字、按钮、四角
./overlay-test/v1/test-window-overlay.sh --app PopAgent --panel-only
```

多个同名窗口时，先 `--list`，然后使用真实 ID，或传 `--frontmost` 选最前可见窗口；下面的 `2030` 只是本机历史值：

```bash
./overlay-test/v1/test-window-overlay.sh --window-id 2030 --duration 1800
```

脚本每次都会重新编译并转发参数。已有编译产物时，也可以直接运行：

```bash
./overlay-test/v1/build/WindowOverlayProbe.app/Contents/MacOS/WindowOverlayProbe --app PopAgent --duration 1800
```

App 是 `LSUIElement` 后台辅助应用，没有常规 Dock 图标。Bundle ID 为 `com.cabinw.kkremote.overlay-probe`，显示名为“KKRemote 遮罩测试”。

目标筛选默认要求唯一匹配（加 `--frontmost` 时取该应用最前窗口）；找不到或匹配多个时会退出并提示选择窗口。`--app` 匹配 `--list` 输出中的 owner，默认 `X`。`--window-id` 优先于 owner。`--appearance` 支持 `auto`（默认，跟随系统）/ `light` / `dark`（也可在菜单栏“▣ 遮罩测试”中实时切换）。`--corner-radius` 可按需覆盖窗口圆角（默认全屏 0pt、macOS 26+ 为 22pt Apple 连续圆角曲线、更早系统 12pt）。`--duration` 应传正数秒数。

### 停止和重启

- 点击控制条“结束”，或菜单栏“▣ 遮罩测试”中的“结束测试”。
- 前台终端启动时可用 Ctrl-C；也可先用 `pgrep -fl WindowOverlayProbe` 确认具体探针 PID，再只停止该 PID。
- 不要批量关闭目标应用，不要叠加启动多个探针。

常见日志：`START`、`FRAME`、`VISIBILITY visible`、`VISIBILITY occluded-by-…`、`STYLE`、`STOP`。

## 4. V1 已定稿的视觉约束

1. 参考 ego 的“workspace 正在被控制”状态，但配色使用紫、粉、橙、黄渐变。
2. 整窗连续覆盖，同时保证中央正文区通透清晰、边缘浓聚明显。
3. 持续流动，不接受全局呼吸导致某一瞬间颜色消失。
4. 保留点阵，去掉横向扫光条、强对比硬圆点和整齐显眼的静态波点网格，转为克制的细腻点阵与清晰随机点位星闪。
5. 毛玻璃控制条无明显硬边框，四角无白色直角延伸，保持放大后约 `392 × 74 pt` 尺寸与上移布局。

## 5. V1 参数与修改位置

所有实现都在 [WindowOverlayProbe.swift](WindowOverlayProbe.swift)；建议按类型/函数名定位。

### 彩色遮罩：`OverlayCanvas` (`NSView` + `CAMetalLayer` + Metal 着色器)

| 项目 | 当前值 / 行为 | 修改入口 |
| --- | --- | --- |
| 窗口内圆角 | 全屏 0 pt、macOS 26+ 22 pt 连续超椭圆曲线 `p=2.85`（支持 `--corner-radius`） | `Probe.cornerRadius(for:)`、`insideDistance` |
| 渲染架构 | 单 pass Metal 片段着色器，60 fps（隐藏时自动暂停） | `overlayShaderSource`、`OverlayCanvas` |
| 三层合成 | 底层极轻洁净雾膜（`fogAlpha` 中央 `0.025`/`0.038`）+ 中层统一匀速旋转五色渐变光场 + 上层克制点阵与随机星闪 | `overlayFragment` |
| 覆盖强弱 | 中央充分收轻保证正文通透（浅色 `0.075` / 深色 `0.070`），`edgeWidth` 取 `min(w, h) * 0.18`（36–125 pt），向边缘平滑浓聚至 `0.76`（上限 `0.90`/`0.92`）；三档强度 `[0.75, 1.0, 1.32]` | `smoothEdgeProximity`、`OverlayStyle.intensity` |
| 配色与明暗适配 | 有序五色日落极光光谱（长春花蓝 → 电紫 → 玫瑰粉 → 珊瑚橙 → 暖蜜金），相邻色相顺滑过渡无杂斑；深色中区保持纯正蓝紫玫瑰冷光 | `linearRamp5`、`pastelSpectrum` / `richGlowSpectrum` / `darkCoolSpectrum` / `darkEdgeSpectrum` |
| 流动光场 | 整窗统一梯度轴稳步顺时针旋转（`0.72 rad/s` + 轻微正交柔弯）与绕边对称高光波峰 `arc`/`crest`（规律平滑、无零散色块与横向扫条） | `overlayFragment` |
| 点阵与星闪 | 间距 8.5 pt，常态收轻避免刻意网格感（基亮浅色 `0.028→0.30` / 深色 `0.018→0.26`，`edge^1.35`，星芯 `σ=0.42` + 轻柔晕 `0.07`）；每个闪烁周期通过 `cycle = floor(phaseClock)` 重新计算随机门限（主星闪 `>0.952`、次星闪 `0.875–0.952`），闪烁瞬间同步放大亮芯（`+0.36`/`+0.15`）与 `1.45×` 光晕（`+0.30`/`+0.09`） | `dotShape`、`dotLevel`、`sparkMain` / `sparkSoft` |
| 抗色带 | 静态胶片微颗粒，消除大面积平滑渐变的 8-bit 色带 | `grain` |

着色器源码内联在 `WindowOverlayProbe.swift` 并通过 `device.makeLibrary(source:)` 运行时编译，保持单文件 `swiftc` 构建。遵守系统“减弱动态效果”与“降低透明度”辅助功能设置。

### 毛玻璃控制条：`BannerView`、`PillButton`、`SpinnerMark`、`ShimmerLabel`

| 项目 | 当前值 / 行为 |
| --- | --- |
| 显示尺寸 | 原生基准 392 × 74 pt；窄于 424 pt 的窗口按比例等比缩放 |
| 位置 | 水平居中；底部间距为 18 pt + 一个控制条高度，并限制不越过顶部 |
| 材质 | `NSVisualEffectView`、`.hudWindow`、`.behindWindow`、`.active`、`.darkAqua` |
| 衬底 | 中性深炭灰 sRGB `(0.145, 0.148, 0.165)`，alpha `0.78`（减弱透明度时 `0.96`）；无边框与强明暗渐变 |
| 圆角 | 20 pt（与 16–18 pt 内边距及 11 pt 按钮圆角形成同心圆角） |
| 标题 | 13.5 pt medium，白色 alpha 0.96，超长自动省略号截断 |
| 说明 | 10 pt regular，白色 alpha 0.52 |
| 状态 | 11 pt semibold，淡紫白带平滑斜向扫光（左对齐 `2pt` 对齐系统文本框） |
| 图标 | 24 × 24 pt 8 刻度旋转指针动画（隐藏时停止刷新，减弱动态效果时静止） |
| 样式按钮 | 72 × 38 pt，显示“标准样式”等；点击循环三档 |
| 结束按钮 | 46 × 38 pt；退出探针 |
| 按钮材质 | 凸起浅透感玻璃：默认白色 alpha 0.095，悬停 0.16，按下 0.05；无描边 |
| 进出场 | 出现时淡入并轻微上浮 8 pt（拖动目标时立即取消动画防滞后）；遮挡时立即隐藏 |

**保留圆角修复：** `layer.cornerRadius` / `masksToBounds` 只处理内容层，不足以可靠裁切独立合成的 behind-window 材质。`updateMaterialMask()` 用相同圆角的 `NSImage` alpha 遮罩赋给 `maskImage`，布局改变时更新并刷新窗口阴影。

## 6. 窗口行为与已验证情况

- `WindowInfo` / `OverlayPanel` / `Probe`：30 Hz 轮询目标位置、遮挡和生命周期；排在目标窗口之上，遇普通窗口遮挡或最小化时自动隐藏；忽略同进程左上角红黄绿辅助小窗与测试光标窗口；拖动、缩放、跨屏跟随已在基础探针逻辑中支持。
- 已在 X（`window=2030`）及 PopAgent（`window=5063`、`640×880`）上通过实机桌面 `screencapture` 与离屏多尺寸深浅色渲染验证，确认连续超椭圆四角裁切、旋转五色渐变、克制底纹点阵、随机星点闪烁与毛玻璃控制条均正常合成。
- 未专项测量长时 GPU/内存占用、按钮交互自动化及视频捕获排除；正式接入 KKRemote 时仍需配合会话生命周期、捕获排除与输入控制链路设计。
