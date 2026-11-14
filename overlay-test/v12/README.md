# V12：四边可停靠磁吸迷你胶囊 + 顶栏融合（Magnetic Edge Dock & Titlebar Fusion）

**V12** 将受控状态浮标升级为 **四边自由拖拽 + MagSafe 磁吸停靠** 形态，并默认采用贴合 macOS 窗口标题栏的 **顶栏融合（Titlebar Fusion）** 布局：在 `112×32` 收起态下直接融入标题栏安全区（自动避让红绿灯与窗口内容），悬停或触发时平滑展开为 `426×74` 交互控制栏。

## 交互与视觉特性

1. **窗口置于遮罩上方 + 零内容遮挡**：
   - 将外扩 `34 pt` 的 Metal 光晕层置于被控窗口**正下方**（`overlayBelowTarget = true`）且严格只绘制窗口外围轮廓与光晕（`dOut >= 0`），彻底避免 WindowServer 全窗透明合成对目标窗口正文/标题栏字体造成的发虚或底色渗透。
   - **默认顶栏融合**：收起态胶囊（`112×32`）置于窗口顶部标题栏垂直居中位置（避开左侧交通灯 `86 pt`），悬停平滑展开为 `426×74`；控制条已将 `NSVisualEffectView` 背景材质与前景文字分层，所有按钮与文字坐标均像素取整对齐以保持 Retina 锐利度。
2. **四边磁吸停靠（4-Edge Magnetic Dock）**：
   - 按住胶囊任意空白区拖动超过 `3 pt`，窗口**四条外侧边界**立即浮现半透明 **MagSafe 外置磁吸引导轨**，并实时高亮即将吸附的目标边缘；松手即平滑磁吸贴边。
   - **轻点胶囊**：按 `顶栏 -> 右侧 -> 底边 -> 左侧` 顺序循环切换停靠边。
   - **菜单栏 `▣ V12`**：支持菜单快捷键 `1–4` 直接切换 `顶栏融合 / 底边停靠 / 左侧边停靠 / 右侧边停靠`。
3. **窗外宝石轮廓与底部阴影补偿**：
   - 沿 `n=2.85`（`R=22`）连续超椭圆外侧绘制高饱和双层发光轮廓、Ambilight 外溢光晕与当前停靠边局部聚光；针对 macOS 窗口底部的原生投影衰减做了局部提亮补偿，四周观感均衡。

## 快速运行

```bash
# 列出当前可跟踪窗口
./overlay-test/v12/test-window-overlay.sh --list

# 默认：顶栏融合 + 收起迷你胶囊（可拖拽至四边或轻点切换）
./overlay-test/v12/test-window-overlay.sh --app PopAgent --style standard

# 指定初始停靠边或保持展开态
./overlay-test/v12/test-window-overlay.sh --app PopAgent --dock right
./overlay-test/v12/test-window-overlay.sh --app PopAgent --dock bottom --always-expanded
```
