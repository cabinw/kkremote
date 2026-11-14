# V13：窗外精密取景框 + 双星巡航外框（Capture Viewfinder & Dual-Comet Outer Rim）

**V13** 在保留“窗口 100% 居于遮罩上方（零窗内像素覆盖、原生字体锐利）”与“四边可拖拽磁吸控制胶囊”的基础上，将单纯的背景光晕升级为更具**实时捕获语义与动态 Telemetry 辨识度**的窗外光学取景结构：

1. **四角精密取景锁定角标**：
   - 在目标窗口 `R=22`（`n=2.85`）四个圆角外侧 `5.2 pt` 悬浮四组同心光学 `L` 型圆弧角标（轻柔呼吸），一眼即知该窗口处于受控捕获状态，哪怕在纯白桌面/浅色壁纸上也清晰可辨。
2. **双星流光巡航尾迹**：
   - 沿窗口外缘周长轨道运行两枚对角同步巡航的青翠/冰蓝彗星流光脉冲，以连续流动的尾迹传递“实时推流连接在线”的生命感。
3. **窗外透明零发虚 + 四边磁吸**：
   - Metal 叠加层仅在目标窗口正下方绘制窗外 `36 pt` 区域，被控窗口与标题栏 100% 原生清晰；底部（或拖至任意三边）附着去糊分层控制胶囊，拖拽超过 `3 pt` 即在四边外缘亮起 MagSafe 吸附引导轨。

## 快速运行

```bash
# 查看可跟踪窗口
./overlay-test/v13/test-window-overlay.sh --list

# 默认：底边收起胶囊 + 窗外取景框与双星流光
./overlay-test/v13/test-window-overlay.sh --app PopAgent --style standard

# 指定初始停靠边或常驻展开态
./overlay-test/v13/test-window-overlay.sh --app PopAgent --dock right
./overlay-test/v13/test-window-overlay.sh --app PopAgent --always-expanded
```
