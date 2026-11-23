# V4 全窗液态玻璃面板（Full-Window Liquid Glass Sheet）

更新日期：2026-11-13。从纯边缘玻璃框升级为“整块半透液态玻璃片覆盖全窗”效果，兼顾全身玻璃质感与正文辨识度。

## 核心特点

- **全窗真磨砂玻璃片**：`LiquidGlassSheetView`（`NSVisualEffectView`）按连续超椭圆轮廓生成全窗平滑渐变遮罩——中央以轻薄磨砂（柔和 `0.10` / 标准 `0.16` / 鲜明 `0.24`）保留正文锐度与对比度，向窗边渐增到厚实玻璃倒角（`0.78–0.92`）。
- **整面光学平板 + 斜向反光与 3D 倒角棱边**：Metal 着色器叠加轻薄冷矿物石英玻璃吸收层，使斜向玻璃反光条（`mainBand` / `crispBand` / `hairlineGlint` + `topWash`）在白底窗口上同样清晰可辨；配合方向光照 3D 倒角脊（`chamferLine`）、菲涅尔外唇、微弱 RGB 弯月面色散与晶尘闪烁。

## 运行命令

```bash
./overlay-test/v4/test-window-overlay.sh --app PopAgent
./overlay-test/v4/test-window-overlay.sh --app PopAgent --style vivid
./overlay-test/v4/test-window-overlay.sh --app X --appearance dark
```
