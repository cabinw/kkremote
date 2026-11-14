# 窗口遮罩试验与多方案对比入口

更新日期：2026-11-14。此目录包含 KKRemote 被控窗口视觉遮罩的 15 套独立可运行对比方案（`v1`–`v15`），**尚未接入 KKRemote 正式应用**。

## 1. 方案目录总览

| 版本 | 方向 | 视觉与交互特点 | 详细说明 |
| --- | --- | --- | --- |
| [v1/](v1/) | 定稿基准版 | 全窗克制五色旋转渐变 + 细腻微底纹点阵 + 每周期随机抽签星点闪烁 | [v1/README.md](v1/README.md) |
| [v2/](v2/) | 极简棱镜光带 | 零中心底色与点阵，仅沿 `n=2.85` 连续圆角边缘滑行 6 色环形焦散光带 | [v2/README.md](v2/README.md) |
| [v3/](v3/) | 活体事件驱动 | 待机近乎隐退；仅在指针轨迹和点击脉冲周围局部唤醒点阵星闪与波纹 | [v3/README.md](v3/README.md) |
| [v4/](v4/) | 全窗液态玻璃面板 | 全窗真磨砂玻璃覆盖（中央轻透、边缘厚倒角 `NSVisualEffectView`）+ 斜向双反光与 3D 倒角弯月面 | [v4/README.md](v4/README.md) |
| [v5/](v5/) | Ego Lite 复刻版 | 对标 120fps 实录还原：全窗 `9.0 pt` 针尖白点阵 + `1.55 s` 横扫光浪 + `1.77 s` 反相矢车菊蓝呼吸 | [v5/README.md](v5/README.md) |
| [v6/](v6/) | 智能折叠 + 光环联动 | 闲置 4 秒自动缩成 `112×32` 迷你胶囊，悬停展开，遮罩随控制条轮廓投射柔性联动光环 | [v6/README.md](v6/README.md) |
| [v7/](v7/) | 外溢环境光 | 将叠加层外扩至窗体外 `40 pt` 阴影区绘制 Ambilight 呼吸光晕，窗内保持 >99% 零内容遮挡，仅留 `~1.3 pt` 锐利锁边与折叠胶囊锚点 | [v7/README.md](v7/README.md) |
| [v8/](v8/) | 接驳脉冲丝带 | 以底部折叠胶囊与底边间凹面光学接口为发射源，双路对称光纤脉冲沿左右下角攀升、顶部汇合回传，下重上轻零遮挡（已淘汰） | [v8/README.md](v8/README.md) |
| [v9/](v9/) | 丝绸干涉极光边 | 高饱和薄膜干涉五色环 + 波动起伏的丝绸光帘与滑动折光脊，加厚高对比外脊在白底同样醒目、正文区保持清透 | [v9/README.md](v9/README.md) |
| [v10/](v10/) | Ego Lite × V6 融合态 | 将 V5 Ego Lite（`9.0 pt` 点阵 + `1.55 s` 扫光浪 + `1.77 s` 矢车菊蓝呼吸）与 V6 智能折叠胶囊深度合流，扫光过胶囊同步亮起微光环 | [v10/README.md](v10/README.md) |
| [v11/](v11/) | 多态状态语义切换 | 遮罩色彩与动效随连接态平滑 morph（推流青蓝 / 暂停暖琥珀 / 重连青橙雷达 / 隐私紫红加密帷幕），支持点击胶囊、菜单或 `--cycle` 实时切换 | [v11/README.md](v11/README.md) |
| [v12/](v12/) | 窗上磁吸胶囊 + 顶栏融合 | 遮罩置底外扩 `34 pt` 渲染使被控窗口 100% 居于上方零发虚；文字与磨砂分层去糊，支持拖拽显露窗外四边 MagSafe 导轨磁吸、轻点与 `1–4` 切换停靠 | [v12/README.md](v12/README.md) |
| [v13/](v13/) | 窗外取景框 + 双星巡航 | 在窗口正下方外扩 `36 pt` 绘制同心四角光学取景锁定角标与双对角流光彗星巡航尾迹，保持窗内零覆盖锐利字体与底边默认可拖拽四边磁吸胶囊 | [v13/README.md](v13/README.md) |
| [v14/](v14/) | 量子棱镜全息极光 | 窗外 `44 pt` 三阶谐波起伏极光浪、四角棱镜色散裂变与 6 道交错光纤光子群流；轻点胶囊发射量子脉冲波并切换 4 套光谱主题，拖拽磁吸四边 | [v14/README.md](v14/README.md) |
| [v15/](v15/) | 零边框立体氛围舞台 | 完全取消任何窗边轮廓线，在窗口下方外扩 `78 pt` 渲染空间舞台（`nebula` 星云萤火 / `spotlight` 聚光灯台 / `caustics` 水波焦散），窗体浮起且字体零发虚 | [v15/README.md](v15/README.md) |

## 2. 目录结构

```text
overlay-test/
├── README.md                         本文：多版本对比总览与运行入口
├── .gitignore                        忽略各版本本机 build/ 及大体积参考录屏
├── shared/                           V2–V15 共用的 AppKit 跟随引擎、Metal 基础库与构建脚本
│   ├── OverlayProbeCore.swift
│   └── build-and-run.sh
├── v1/                               V1 完全独立归档源码、脚本与本机编译产物
├── v2/ … v15/                        各对比方案的效果实现、README 与快速运行脚本
├── docs/
│   └── iteration-history.md           历史试验与版本演进记录
└── reference/                        原始参考图、参考录屏及早期抽帧采样产物
```

## 3. 快速对比运行

在项目根目录执行对应版本的运行脚本，传入同一个目标窗口对比观感（运行下一版前点击“结束”或停止前一探针即可）：

```bash
# 查看任意版本参数
./overlay-test/v2/test-window-overlay.sh --help

# 在 PopAgent 窗口逐一对比 V1 – V15
./overlay-test/v1/test-window-overlay.sh --app PopAgent
./overlay-test/v2/test-window-overlay.sh --app PopAgent
./overlay-test/v3/test-window-overlay.sh --app PopAgent
./overlay-test/v4/test-window-overlay.sh --app PopAgent
./overlay-test/v5/test-window-overlay.sh --app PopAgent
./overlay-test/v6/test-window-overlay.sh --app PopAgent
./overlay-test/v7/test-window-overlay.sh --app PopAgent
./overlay-test/v8/test-window-overlay.sh --app PopAgent
./overlay-test/v9/test-window-overlay.sh --app PopAgent
./overlay-test/v10/test-window-overlay.sh --app PopAgent
./overlay-test/v11/test-window-overlay.sh --app PopAgent --cycle
./overlay-test/v12/test-window-overlay.sh --app PopAgent
./overlay-test/v13/test-window-overlay.sh --app PopAgent
./overlay-test/v14/test-window-overlay.sh --app PopAgent
./overlay-test/v15/test-window-overlay.sh --app PopAgent

# 深色窗口测试（如 X / Terminal）
./overlay-test/v5/test-window-overlay.sh --app X --appearance dark

# V6 / V7 / V9–V15 单独查看折叠胶囊、常驻展开态或固定状态/舞台/停靠边
./overlay-test/v11/test-window-overlay.sh --app PopAgent --state privacy --always-expanded
./overlay-test/v15/test-window-overlay.sh --app PopAgent --stage spotlight --dock right --always-expanded
```

## 4. 边界与协作约定

- 所有版本均为本机独立样式探针：不捕获视频、不联网、不注入输入、不申请辅助功能或屏幕录制权限。
- 请继续将本试验修改限定在 `overlay-test/` 目录内，不要改动仓库中其他并发开发的文件。
