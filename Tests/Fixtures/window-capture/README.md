# Real browser capture fixture

This is real HTML text/layout/scrolling plus a native `<video>` element. It is not the synthetic `DesktopPattern` renderer. The Mac captures the explicitly selected browser window using ScreenCaptureKit, including browser chrome. No audio is sent.

Serve on loopback with a local, untracked MP4:

```bash
python3 scripts/serve-capture-fixture.py --media /absolute/path/clip.mp4
```

Open `http://127.0.0.1:47980/` in a separate normal browser window. For a 2× display, set the entire window to 1280×720 points and verify the capture report: 1280×720 source points, scale 2, 2560×1440 output. The video is fitted inside the content area; browser chrome and controls reduce its displayed area. A 1440p transport does not imply a full-frame 1440p video image.

Buttons select scrolling, video, or pause. The UTC clock changes with browser animation callbacks and provides a visible motion reference. It does **not** by itself measure remote input-to-photon latency. `window.captureTest.stats()` provides browser animation and video callback counters; use deltas between timed samples. Initial video preload frames and mode changes must be excluded.

The local validation clip is a silent, approximately 60-second, stream-copied excerpt starting near 120 seconds from **Big Buck Bunny**, Blender Foundation / blender.org, licensed **CC BY 3.0**. It is 3840×2160 at 60 fps, not frame-interpolated by this project. Download the `bbb_sunflower_2160p_60fps_normal.mp4.zip` asset from [Blender's official directory](https://download.blender.org/demo/movies/BBB/); see [film credits and license](https://peach.blender.org/about/). Media binaries are excluded from Git. Preserve attribution if sharing an excerpt or captured video.

```bash
ffmpeg -ss 120 -i bbb_sunflower_2160p_60fps_normal.mp4 \
  -t 60 -map 0:v:0 -an -c:v copy -movflags +faststart clip.mp4
```

Use the Mac Lab's `--list-windows` or “刷新窗口” to select this window explicitly. Hidden browser automation surfaces may enumerate as windows but produce no complete ScreenCaptureKit frames; use a normal visible window. Do not capture a browser window containing unrelated private tabs.

## HDR fixtures

Run `bash scripts/generate-hdr-fixture.sh` to generate a 20-second looping 1440p60
Main10 BT.2020/PQ code-value test pattern. It is explicitly synthetic; it is not a
conversion of SDR film intended to represent a mastered HDR scene. Inspect its
VUI and container metadata using the emitted `ffprobe` result.

```bash
python3 scripts/serve-capture-fixture.py --media /absolute/path/clip.mp4 \
  --reference-media "$PWD/.build/hdr/pq60-reference.mp4" \
  --hdr-media /absolute/path/apple-hdr.mp4 --port 47981
```

Open `http://127.0.0.1:47981/?fixture=hdr60` for the 60 fps pattern, or
`http://127.0.0.1:47981/?fixture=hdr-film` for real HDR film. The separate film used
locally comes from [Apple's Advanced Stream example](https://developer.apple.com/streaming/examples/advanced-stream-dv-atmos.html),
selecting its **hvc1 / PQ** 3840×2160 variant. The downloaded 60-second, video-only
excerpt is **23.976 fps** and remains untracked. A 60 Hz capture of this film does
not mean it contains 60 unique film frames per second. No Dolby Vision or dynamic
HDR metadata is promised for the captured window.

## Real HDR film and grayscale

`python3 scripts/generate-hdr-gray.py` generates a neutral 2560×1440, 10-bit
BT.2020/PQ chart directly as limited-range YUV. It uses the
[BT.2100 inverse PQ EOTF](https://registry.khronos.org/DataFormat/specs/1.4/dataformat.1.4.html)
to author the near-black and highlight levels. The first row is
0 / 0.01 / 0.03 / 0.1 / 0.3 / 1 / 3 / 10 nits; the second is
10 / 25 / 50 / 100 / 203 / 400 / 700 / 1000 nits. The third row is a
continuous 10-bit PQ code-value ramp from black to the 1000-nit code.
These labels describe the **input signal**, not measured phone luminance.

The fixture is encoded losslessly using ffmpeg/libx265, with a bit-exact decoded
first-frame comparison and Main10/PQ/range/frame-count checks. This offline
fixture encoder does not replace the live VideoToolbox encoder. A trial lossy VT
fixture introduced up to two code values of ramp error; the lossless fixture
removes that ambiguity. The 10-second, 60 fps file contains a static chart;
only the browser clock necessarily changes at display cadence.

Add `--gray-media "$PWD/.build/hdr/pq-gray-reference.mp4"` to the local server
command. Open `/hdr-quality.html?phase=film` or `?phase=gray` for an individual
phase. `?phase=cycle` or the “自动轮换” button runs 60 seconds of real HDR film,
then 45 seconds of grayscale, repeatedly. Manual phase buttons or pause stop
automatic cycling. The clock/countdown exposes the active phase; brief media
loads at a phase transition must be separated from within-phase network freezes.

The browser window remains the captured source. Changing these fixtures requires
neither a new TestFlight build nor new pairing credentials or media endpoints.

## T01 repeatable load suite

`high-load.html` adds independently selectable native-60-fps video, four-column
DOM scrolling, static text/line detail, image pan/zoom/rotation, and a generated
SVG schematic. The schematic is a deterministic CAD-style stress workload, not
a real customer document. The image transform is procedural motion of a still,
not a claim of native film frames. All these sources are SDR content; a Main10/PQ
capture transport does not turn them into HDR-mastered scenes. Keep the existing
HDR film and grayscale suite for color validation.

Prepare the local assets once (media remains ignored by Git):

```bash
python3 scripts/prepare-load-fixtures.py \
  --source .build/window-capture/media/bbb_sunflower_2160p_60fps_normal.mp4
python3 scripts/serve-capture-fixture.py \
  --media .build/load-fixtures/bbb-highmotion-60.mp4 \
  --photo .build/load-fixtures/photo.jpg --port 47982
```

The requested excerpt starts at 420 seconds and lasts 30 seconds. Stream-copy
preroll makes the actual prepared file 33.5 seconds / 2010 frames; the manifest
records the actual metadata, original and derived SHA-256, and credit. No frames
are interpolated. `photo.jpg` is extracted at 9 seconds of this prepared clip.

Open `http://127.0.0.1:47982/high-load.html?mode=video`. Other explicit modes are
`scroll`, `static`, `photo`, and `diagram`. `speed=1|2|3` changes the procedural
motion speed; it never changes the video's playback rate. Use the same mode,
speed, window dimensions, source asset hashes and restart position for a
comparison. The visible telemetry shows browser animation callbacks, video
callbacks / unique media timestamps, local video drops, visibility, viewport
and pixel scale; none is a physical-display or end-to-end latency measurement.

`immersive=1` removes the fixture's header/footer space, keeping the browser window
and capture resolution unchanged. Use “退出铺满 / Esc” to return to controls.
The [initial calibration report](../../../docs/testing/真实负载素材校准.md) records
both ordinary and immersive cases; none yet passes the sustained 15–20 Mbps gate.

An existing host can be sampled without restarting or launching another stream:

```bash
python3 scripts/sample-persistent-report.py \
  --report /private/path/to/live/host.json \
  --output .build/load-fixtures/unique-run --duration 55 \
  --label diagram-speed3 \
  --fixture Tests/Fixtures/window-capture/high-load.html
python3 scripts/summarize-lab.py .build/load-fixtures/unique-run --relative-warmup
```

The collector only includes new samples and refuses to combine a detected
session reset. Its output is host-side load calibration, not receiver acceptance.
Preserve the browser telemetry at the beginning and end of the same measurement
when calculating source frame rates. File preparation, first play, seek and loop
boundaries need separate interpretation from transport freezes.

### 通信 v1 固定配方

- 高负载图纸：`high-load.html?mode=diagram&speed=3&panels=4&immersive=1`，4 个相位不同的图纸面板。H.264 / HEVC 的实际码率分别校准。
- 严格静态：`high-load.html?mode=static&strict=1&immersive=1`，首份观测后停止更新页面计数；不要以静态低 fps 判冻结。
- 30 分钟混合：`high-load.html?mode=cycle&speed=3&panels=4&immersive=1`，每 120 秒在图纸、滚动、原生 60 fps 视频之间循环。

每次实验保存当时的 HTML 和 SHA-256，不能用后续改过的页面替代原始配方。

持续热测试使用 `mode=cycle&phaseSeconds=100&speed=3&panels=4&immersive=1`，每段 100 秒，完整循环 5 分钟，使首 / 末 5 分钟内容比例一致。未指定 phaseSeconds 时保留每段 120 秒。

### 绘制瓶颈对照

`raster=1` 将同一 SVG 电路图先画到 3200×1600 的静态位图，再在四块面板上执行相同平移、缩放和旋转。它不复制视频帧、不降低输出尺寸或改变 3× 运动速度；用于排除每帧重绘上万个 SVG 元素的源端开销。原始 live SVG 是 `raster` 不设或为 0，两种源分开记录，不能混称同一次标定。开始前检查 `diagramRasterReady=true`。

长测还应记录刷新率与源端 complete / idle 回调；若源本身只有 30–40 fps，不得把接收端同样的 fps 记作网络丢帧。

可指定 `mode=cycle&cycleScenes=scroll,video&phaseSeconds=150&speed=3&panels=4&immersive=1`，在真实滚动和原生 60 fps 视频之间交替，每五分钟重复；默认仍为图纸 / 滚动 / 视频三段。两种素材负载不同，必须分开标注，不能拿双段结果替代四面板图纸压力验收。页面指标记录 `cycleScenes`。
