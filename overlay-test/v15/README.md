# V15：零边框立体氛围舞台与漂浮萤火场（Zero-Border Volumetric Stage）

**V15** 彻底告别一切框线、描边与角标，转而在被控窗口下方延展出一片 `78 pt` 宽的**零边框空间舞台**——目标窗口完全居于最上方保持 `100%` 原生字体清晰度，仿佛物理“浮空”于桌面立体氛围场之上：

1. **零框线（Zero Perimeter Line）**：
   - 着色器完全移除矩形描边与轮廓线，光场从窗口下方柔和地自然溢出并无边界溶入桌面背景（绝无裁切矩形感）。
2. **三大可切换无边框立体舞台（轻点胶囊或菜单 `1–3` 平滑过渡）**：
   - **`nebula`（星云萤火舞台，默认）**：3 阶 FBM 缓慢涌动的极光星云雾团（底部略厚形成漂浮托底感），外加 18 枚游曳闪烁的柔光虚化萤火粒子。
   - **`spotlight`（英雄聚光灯台）**：对称斜向体积光束与窗口下方非对称“地面反弹光斑”共同构成产品发布会式悬浮舞台，辅以漂浮微光尘埃。
   - **`caustics`（流体水波焦散）**：双波干涉域扭曲焦散网格投射到窗后周围桌面，形成如水面折射波动般的青翠流体池。
3. **非框体拖拽锚点与去糊分层胶囊**：
   - 胶囊保持分层去糊与锐利文本，拖拽超过 `3 pt` 仅在四边外围浮现柔和发光球状锚点（非方框导轨），松手磁吸停靠。

## 快速运行

```bash
# 查看可跟踪窗口
./overlay-test/v15/test-window-overlay.sh --list

# 默认：星云萤火舞台（轻点胶囊可在 3 种氛围间切换，拖拽可停靠四边）
./overlay-test/v15/test-window-overlay.sh --app PopAgent --style standard

# 直接查看聚光灯台或流体水波焦散
./overlay-test/v15/test-window-overlay.sh --app PopAgent --stage spotlight
./overlay-test/v15/test-window-overlay.sh --app PopAgent --stage caustics
```
