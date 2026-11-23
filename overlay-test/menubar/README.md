# OverlayTest 菜单栏切换工具

`overlay-test/menubar/` 提供一个常驻顶部状态栏（`LSUIElement`）的轻量切换器 **OverlayTest**，默认挂载到 **`PopAgent`** 窗口，方便在菜单栏中逐一点击或用快捷键顺次预览 `V1`–`V15` 全部遮罩方案。

## 启动方式

```bash
# 默认以 PopAgent 为演示目标，启动后自动挂载 V1，随后可在菜单栏依次切换 V1–V15
./overlay-test/menubar/test-menubar.sh

# 指定从某一版本开始，或启动时先不挂载（--start none）
./overlay-test/menubar/test-menubar.sh --start v15
./overlay-test/menubar/test-menubar.sh --start none

# 指定其他演示应用或强制度模式
./overlay-test/menubar/test-menubar.sh --app X --style vivid --appearance dark
```

编译后的独立 `.app` 位于 `overlay-test/menubar/build/OverlayTestMenuBar.app`（已被 `.gitignore` 忽略），在 Finder 中直接双击亦可运行并自动定位同仓库 `overlay-test/` 目录。

## 主要功能

- **一键遍历 `V1`–`V15`**：顶部菜单直接列出全部 15 套方案，当前运行项带勾选标记；支持 `← 上一个效果`（`[`）与 `→ 下一个效果`（`]`）顺次体验。
- **专属子模式直达**：在「版本专属子模式」子菜单中可直接选择 `V11` 连接语义状态（`live/paused/reconnecting/privacy/cycle`）、`V14` 光谱主题（`prism/violet/solar/emerald`）与 `V15` 无边框舞台（`nebula/spotlight/caustics`），点击即自动切换并实时生效。
- **共享外观与胶囊参数**：支持实时调节强度（`subtle/standard/vivid`）、明暗（`auto/light/dark`）、停靠边（`top/bottom/left/right`）与胶囊常驻展开（`--always-expanded`）；默认传入 `--no-status-item` 隐藏子探针额外状态栏图标以保持菜单栏整洁（可在参数菜单取消勾选恢复）。
- **演示目标切换**：默认自动锁定 `PopAgent` 前景窗口，展开菜单时也会刷新「演示目标窗口」列表以切换其他桌面窗口。
- **单活与自动清理**：切换方案时会自动终止前一个子探针；若子探针源码较旧或尚未编译，将异步自动编译后再挂载；退出菜单栏工具时自动清理当前运行的探针。
