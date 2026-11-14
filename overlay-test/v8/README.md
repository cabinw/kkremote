# WindowOverlayProbe V8 — 接驳脉冲丝带（Tether Pulse）

本目录是受控窗口视觉层原型 **V8**，将焦点从"均匀包围四边"转向"**控制接口接驳 + 双向脉冲信号流**"：把视觉重心锚定在底部控制胶囊与窗口下缘的交汇插座上，像一根正在传输实时遥测数据的光纤丝带。

## 关键特性

- **凹面光学接驳桥（Dock Tether）**：当底部迷你胶囊（`112×32`）贴合下缘折叠停靠时，其底部正中生出平滑内凹的光学插头接口紧扣至底边导轨，左右边缘辅以 `~1.3 pt` 锐利锁边与微光溢流；展开控制条时接驳颈平滑退回底边底座发光槽，绝不横切内部输入区控件。
- **双路对称脉冲光弹**：信号光包自底部胶囊接口发出后向左右底角分流，沿左（天青-薄荷）、右（钴蓝-电紫）两条超椭圆微细光轨向上攀升，至顶部中点轻柔汇合，并叠加微弱的紫玫瑰回传心跳脉冲。
- **下重上轻零干扰阅读区**：`cradleWeight` 将光晕与导轨权重集中在下缘与底角，上半部分逐步收敛为极细 `1.0 pt` 晶体丝线，正文与顶部标题栏几乎完全不被干扰（`d > 17 pt` 内透明归零）。

## 运行方式

```bash
./test-window-overlay.sh --app PopAgent --style standard
./test-window-overlay.sh --app PopAgent --style vivid --collapsed
./test-window-overlay.sh --app PopAgent --style standard --always-expanded
```

## 参数说明

除共享核心参数（`--list`、`--app`、`--window-id`、`--frontmost`、`--duration`、`--style subtle|standard|vivid`、`--appearance auto|light|dark`、`--corner-radius`、`--panel-only`）外，V8 额外支持：

- `--collapsed`：启动时即保持收起为 `112×32` 迷你状态条
- `--always-expanded`：取消闲置 4s 自动收起，控制栏常驻展开
