# V2 极简棱镜光带（Minimal Prism Ribbon）

更新日期：2026-11-13。尝试完全清零中央遮罩与中心点阵，把信号纯粹收敛到连续圆角边缘的棱镜流光。

## 核心特点

- **中央 100% 透明通透**：`d > maxReach`（76–108 pt）直接归零，不给正文或视频叠加任何底色或网格。
- **无缝 6 色环形色谱**：`cyclicPrism6` 采用 蓝 → 紫 → 玫红 → 珊瑚橙 → 暖金 → 桃兰 闭合循环，经过 Peach Orchid 过渡回 Sapphire Blue，消除边界跳色与发灰过渡。
- **焦散光带 + 高饱和棱镜边**：`insideDistance(n = 2.85)` 精准贴合 macOS 26 22 pt 连续圆角；浅色模式下调高色素饱和度（去白洗边）让白色界面依然一眼鲜明。外圈光带宽度随柔和/标准/鲜明三档在 `2.2–4.4 pt` 切换、内羽纵深在 `22–44 pt`、基浓 `0.30–0.62` 拉开鲜明层次感，并伴随双波包 `caustic` 与边缘微星闪滑行。

## 运行命令

```bash
./overlay-test/v2/test-window-overlay.sh --app PopAgent
./overlay-test/v2/test-window-overlay.sh --app X --appearance dark
```
