# V6 智能折叠控制条与光场联动（Smart Collapsible Banner + Aura Link）

更新日期：2026-11-13。针对较窄窗口或底部密集交互区（如聊天输入框、终端命令行）控制条长期占位的痛点，设计可自动收折的双态控制条与实时同步光环的联动遮罩。

## 核心特点

- **双态自适应控制条**：默认展示完整操作条（`426 × 74 pt`，含“标准样式 / 自动 / 结束”），闲置 4 秒后自动缩成贴底迷你胶囊（`112 × 32 pt`，大幅减少遮挡面积）；鼠标悬停即平滑展开，点“自动/常驻”可固定状态。
- **胶囊光环实时联动**：着色器每帧读取 `bannerRect` 与 `bannerFold`，在控制条正后方轻柔避让减噪，同时环绕控制条轮廓投射同步缩伸的柔性光源光晕。
- **调试参数**：支持 `--collapsed`（立即查看折叠小胶囊）与 `--always-expanded`（固定展开）。

## 运行命令

```bash
./overlay-test/v6/test-window-overlay.sh --app PopAgent
./overlay-test/v6/test-window-overlay.sh --app PopAgent --collapsed
```
