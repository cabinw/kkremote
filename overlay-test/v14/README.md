# V14：量子棱镜全息场 + 多彩声波极光浪（Cyber-Prism & Plasma Aurora）

**V14** 在确保“窗口 100% 居于遮罩上方（零窗内模糊、原生字体锐利）”基础上，将外扩画布拓展至 `44 pt`，打造更具生命力与沉浸科技感的窗外全息光场：

1. **三阶谐波动态极光浪**：
   - 沿窗口四周以三组不同频率与速度实时叠加流动，形成最高舒展至 `~36 pt` 的起伏极光光浪，并混入细腻放射状棱镜微射线。
2. **四角棱镜色散裂变 + 6 道光纤光子群流**：
   - 在四个 `R=22` 超椭圆圆角外侧分裂出三层间距微移的高饱和折射光弧（如晶体棱镜色散），同时 6 枚交错速度和正反方向的光纤粒子沿外框高速穿梭。
3. **交互量子脉冲波 + 四大光谱主题**：
   - **轻点胶囊** 或触发边缘吸附：立即以胶囊为中心向外发射一圈环形与双臂巡航 **量子冲击脉冲波**，并循环切换 4 套精选光谱主题：
     - `prism`：**全息棱镜**（青蓝 → 钴蓝 → 霓虹紫 → 玫瑰粉）
     - `violet`：**紫电超频**（紫外 → 玫红 → 冰紫 → 冰青）
     - `solar`：**炽焰极光**（珊瑚火 → 琥珀金 → 霓虹玫瑰 → 紫罗兰）
     - `emerald`：**矩阵翡翠**（霓虹薄荷 → 深海青 → 钴蓝 → 莱姆绿）
   - **拖拽胶囊 > 3 pt**：四边窗外亮起 MagSafe 吸附引导轨，松手磁吸停靠；菜单栏 `▣ V14` 支持快捷键 `1–4` 直选配色或手动发射脉冲。

## 快速运行

```bash
# 查看可跟踪窗口
./overlay-test/v14/test-window-overlay.sh --list

# 默认：全息棱镜主题 + 底边折叠胶囊（点击胶囊切色+发射脉冲，拖拽吸附四边）
./overlay-test/v14/test-window-overlay.sh --app PopAgent --style standard

# 指定配色主题或初始停靠位置
./overlay-test/v14/test-window-overlay.sh --app PopAgent --theme violet
./overlay-test/v14/test-window-overlay.sh --app PopAgent --theme solar --dock right --always-expanded
```
