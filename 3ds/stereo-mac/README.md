# New 3DS LL 的 Mac 端实时立体视频原型

本目录独立构建。命令行工具从视频文件按帧取图，在 Mac 上生成左右眼画面，输出 800 × 240 的并排 H.264 MP4。每眼保留原始宽高比并居中放入 400 × 240 区域。工具可按片源时间戳模拟播放，也可不限速转换。实验的终点是 Mac 上的 H.264 编码回调。

## 运行

在 Apple Silicon Mac、Xcode 命令行工具和 Swift 6 环境下，从本目录执行。准备脚本下载固定版本的模型和测试片，校验片源并编译模型与程序。验证脚本另需 FFmpeg、ffprobe 和 Python 3。下载和生成物都在本目录忽略的 `.build/` 下。每次转换请使用新的输出文件名。

```bash
./prepare.sh
model=.build/DepthAnythingV2SmallF16.mlmodelc
.build/stereo "$model" .build/sintel.mp4 .build/sintel-fast.mp4 fast > .build/sintel-fast.json
.build/stereo "$model" .build/sintel.mp4 .build/sintel-sbs.mp4 paced > .build/sintel-paced.json
python3 verify.py .build/sintel.mp4 .build/sintel-sbs.mp4
```

输入也可以换成自己的本地 SDR 视频（至少 13 帧）。所有帧都会写入输出文件。实时测试采用顺序处理，同一时刻最多有一帧在编码；遇到超时保留该帧并记录错过的期限。工具输出视频轨，若要在 Mac 上带声音对照观看，可将片源音轨封装进样片：

```bash
ffmpeg -i .build/sintel-sbs.mp4 -i .build/sintel.mp4 -map 0:v:0 -map 1:a:0 -c copy \
    -metadata comment="Stereo conversion of Sintel trailer. (c) Blender Foundation | www.sintel.org | CC BY 3.0." -movflags +faststart .build/Sintel-3DS-preview.mp4
```

## 转换与计时

1. AVAssetReader 顺序读取解码图像。Core Image 应用视频轨的显示方向，等比缩放，生成模型输入与单眼底图。
2. 每帧运行一次 Depth Anything V2 Small FP16（固定 518 × 392 输入，Core ML 可选用全部计算单元），输出归一化相对逆深度。
3. 按深度水平移动像素，每眼最大偏移 3 像素。重叠时保留近处像素，显露的空隙用较远一侧颜色填补。逐帧估计及整数像素位移可能导致运动边缘跳动。遮挡区采用近似填补。
4. VideoToolbox 使用必须具备硬件加速的 H.264 Baseline 编码器、1.5 Mbps 目标码率及关闭重排序的实时配置，输出一条左右并排的视频轨。

前 12 帧预热，单列初始化与首帧耗时。`wall_fps` 是预热后整段的实耗吞吐，包含循环和 MP4 样本写入，止于最后一帧写入，不含最终文件封装。`service_ms` 计入获取解码帧的等待、缩放、深度、合成、编码回调，扣除主动的播放节拍等待。AVAssetReader 可以预解码，因此读取等待不可解释为解码器独立耗时。`release_to_packet_ms` 从该帧计划播放时刻到其编码回调，包含调度抖动和积压；读取下一帧以获得时间戳时最多前瞻一个样本。超时指这个时间超过输入帧自身的持续时间。计时使用单调时钟。

测试输入为 Blender Foundation 的《Sintel》预告片（CC BY 3.0），原片 854 × 480，24 fps，1,253 帧。模型与影片按来源下载。预览为原片的深度合成立体改编。[片源](https://media.w3.org/2010/05/sintel/trailer.mp4) · [Sintel 项目与授权](https://durian.blender.org/sharing/) · [Apple Core ML 模型](https://huggingface.co/apple/coreml-depth-anything-v2-small)

### 复现 30 / 60 fps 压力测试

以下命令将原片相同的 1,253 个视频帧按等间隔加速播放。先生成输入，再串行运行基准。

```bash
for rate in 30 60; do
    ffmpeg -v error -i .build/sintel.mp4 -map 0:v:0 -an \
        -vf "settb=1/60000,setpts=N*60000/$rate" -r "$rate" -fps_mode cfr -frames:v 1253 \
        -c:v libx264 -crf 16 -preset veryfast ".build/sintel-cfr-$rate.mp4"
    .build/stereo "$model" ".build/sintel-cfr-$rate.mp4" ".build/sbs-cfr-$rate.mp4" paced > ".build/paced-cfr-$rate.json"
    python3 verify.py ".build/sintel-cfr-$rate.mp4" ".build/sbs-cfr-$rate.mp4"
done
```

`verify.py` 核对输入与输出帧数、逐帧时间戳、编码和尺寸；解码输出并在采样画面的有纹理区域进行左右眼水平块匹配。结果可验证左右眼存在视差，观影舒适度仍需真机评估。

## 本机实测（2026-11-19）

Apple M5 Max，macOS 27.2.1，优化构建。每组完整输出 1,253 帧，预热后的 1,241 帧计入稳态。各节奏分别测一次。30 和 60 fps 使用同一片源加速后的恒定帧率测试文件。

| 输入节奏 | 实际处理 fps | 计划播放至编码就绪 P50 / P95 / 最大（ms） | 超过帧预算 |
| --- | ---: | ---: | ---: |
| 原片 24 fps | 24.01 | 15.26 / 17.66 / 24.27 | 0 / 1,241 |
| 30 fps | 30.01 | 14.88 / 18.98 / 23.64 | 0 / 1,241 |
| 60 fps | 60.01 | 12.33 / 13.89 / 19.34 | 15 / 1,241 |

不限速的一次实测为 100.24 fps，单帧服务耗时 P50 / P95 为 9.96 / 10.23 ms。24 fps 原片测得初始化 184.69 ms，随后首帧 174.39 ms。稳态阶段，读取、预处理、深度推理、视差合成及 H.264 编码分别用时 0.10、1.36、9.82、0.56、2.25 ms（各自的 P50）。60 fps 的单帧预算为 16.67 ms，平均吞吐达标，个别帧晚于期限。

原片、两个压力输入与各自的编码输出均核对了帧数和逐帧显示时间戳，最大偏差 0 ms。原片每 4 秒取样，共 13 幅；262 个通过置信度筛选的纹理块中有 193 个匹配到了非零水平位移。原片视觉抽查看到两幅完整并排的画面，保留宽银幕黑边。带声音的本地预览使用原片 AAC 音轨离线封装。

本次测量涵盖本地文件取帧及 Mac 端转换、编码。KKRemote 窗口实时采集、网络抖动、3DS 解码与上屏，以及长时间运行和真机裸眼观看效果，留待后续测量。
