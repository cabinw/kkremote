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
