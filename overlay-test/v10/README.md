# WindowOverlayProbe V10 — Ego Lite × V6 融合态

本目录是受控窗口视觉层原型 **V10**，将经过实录校准的 **V5 Ego Lite 全窗点阵波浪光场** 与用户认可保留的 **V6 智能折叠胶囊及光环联动** 无缝融合。

## 关键特性

- **完整保留 Ego Lite 光场引擎**：`9.0 pt` 全窗固定超细针尖白点阵（`σ = 0.46 pt`）、`~1.55 s` 自右向左斜向扫光帘幕与星闪、`~1.77 s / 3.53 s` 对称反相矢车菊蓝周缘呼吸及白边高光。
- **叠加 V6 智能收起胶囊（`426×74 ↔ 112×32`）**：闲置 4 秒自动折起为 `112×32` 迷你状态条，悬停展开，支持点击“自动”或菜单栏固定常驻。
- **胶囊避让与扫光同步脉冲**：胶囊玻璃背板下方自动减噪清空，防止网格点在深色毛玻璃后闪烁；每当 `1.55 s` 光浪扫过胶囊位置时，其周圈同步点亮矢车菊蓝/薰衣草紫联动光环与边缘微星闪。

## 运行方式

```bash
./test-window-overlay.sh --app PopAgent --style standard
./test-window-overlay.sh --app PopAgent --style vivid
./test-window-overlay.sh --app PopAgent --style standard --collapsed
./test-window-overlay.sh --app PopAgent --style standard --always-expanded
```

## 参数说明

除共享核心参数（`--list`、`--app`、`--window-id`、`--frontmost`、`--duration`、`--style subtle|standard|vivid`、`--appearance auto|light|dark`、`--corner-radius`、`--panel-only`）外，V10 额外支持：

- `--collapsed`：启动时即保持收起为 `112×32` 迷你状态条
- `--always-expanded`：取消闲置 4s 自动收起，控制栏常驻展开
