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
