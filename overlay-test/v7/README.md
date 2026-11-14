# WindowOverlayProbe V7 — 外溢环境光（Out-of-Frame Halo）

本目录是受控窗口视觉层原型 **V7**，验证"环境光完全外溢到目标窗口外部阴影区、窗口内部保持 >99% 纯净零遮挡"的设计思路。

## 关键特性

- **外溢渲染画布 (`outerPadding = 40 pt`)**：`OverlayProbeCore` 自动在目标窗口四周各外扩 `40 pt` 空间，并根据屏幕边界智能裁剪；全屏或贴边时平滑收束到边缘。
- **窗口内部 >99% 零遮挡**：仅在 `d ∈ [0, 3.6 pt]` 窗口轮廓线上绘制 `~1.3 pt` 锋利高光锁边，确保画面主体文字、代码块、按钮完全不被着色或雾化；同时在贴边/全屏无外溢空间时仍保持清晰可见的边框识别。
- **Ambilight 双段外发光**：近边高饱和接触光晕（`5.2–9.2 pt`）+ 柔和外扩环境光羽（衰减至 `38 pt` 处归零，严格无方形裁切边界），带微幅呼吸与四色无缝循环渐变。
- **保留 V6 智能收起胶囊与光域锚点联动**：底部胶囊 `426×74 ↔ 112×32` 自动折叠，下方外溢光晕随胶囊位置形成柔和聚光锚点。

## 运行方式

```bash
./test-window-overlay.sh --app PopAgent --style standard
./test-window-overlay.sh --app PopAgent --style vivid --collapsed
./test-window-overlay.sh --app PopAgent --style standard --always-expanded
```

## 参数说明

除共享核心参数（`--list`、`--app`、`--window-id`、`--frontmost`、`--duration`、`--style subtle|standard|vivid`、`--appearance auto|light|dark`、`--corner-radius`、`--panel-only`）外，V7 额外支持：

- `--collapsed`：启动时即保持收起为 `112×32` 迷你状态条
- `--always-expanded`：取消闲置 4s 自动收起，控制栏常驻展开
