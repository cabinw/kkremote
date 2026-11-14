# WindowOverlayProbe V9 — 丝绸干涉极光边（Silk Aurora Ribbon）

本目录是受控窗口视觉层原型 **V9**，针对“边缘太弱不够明显”的问题，采用高饱和珠宝感薄膜干涉色谱与波动丝绸光帘结构，在保持窗口正文区域完全无遮挡的同时显著强化四周辨识度与流动美感。

## 关键特性

- **波动宽幅丝绸光帘**：周界光带不再是固定宽度的机械细框，而是随双频反向谐波 `waveA / waveB` 在 `~6–34 pt` 间自然舒卷起伏（四角处微幅加深舒展），窗体中心区域保持严格零底色。
- **薄膜干涉光学折光脊（Iridescent Caustics）**：色彩随深度 `d` 与角度轻微色散偏移（青绿 → 蓝宝石 → 电紫 → 玫瑰红 → 珊瑚橙五色闭环），光帘内部滑动高亮丝绸褶皱折光脊与贴边内嵌细光丝。
- **浅色底高对比加厚外脊**：贴近边框 `0–3.5 pt` 的外主脊线在浅色模式下保持高饱和度与加粗轮廓（避免白底发虚），兼具醒目识别度与轻柔质感。
- **保留 V6 智能折叠控制胶囊**：底部 `426×74 ↔ 112×32` 自动折叠并附带柔和干涉光环包边。

## 运行方式

```bash
./test-window-overlay.sh --app PopAgent --style standard
./test-window-overlay.sh --app PopAgent --style vivid
./test-window-overlay.sh --app PopAgent --style standard --always-expanded
```

## 参数说明

除共享核心参数（`--list`、`--app`、`--window-id`、`--frontmost`、`--duration`、`--style subtle|standard|vivid`、`--appearance auto|light|dark`、`--corner-radius`、`--panel-only`）外，V9 额外支持：

- `--collapsed`：启动时即保持收起为 `112×32` 迷你状态条
- `--always-expanded`：取消闲置 4s 自动收起，控制栏常驻展开
