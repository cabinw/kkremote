package com.kkremote.android.ui

import android.content.Context
import android.graphics.Bitmap
import android.graphics.SurfaceTexture
import android.os.SystemClock
import android.view.TextureView
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import com.kkremote.android.webrtc.WebRtcRuntime
import org.webrtc.EglBase
import org.webrtc.EglRenderer
import org.webrtc.VideoFrame
import org.webrtc.VideoSink
import org.webrtc.VideoTrack
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Hardware-accelerated OpenGL ES TextureView backed by WebRTC's EglRenderer.
 * Also performs zero-GC double-buffered 160x120 GPU readback at ~7 Hz to drive:
 *   1. Real-time frosted glass (.regularMaterial) backdrop blur beneath floating UI
 *   2. Dynamic WindowEdgeColor ambient canvas & status-bar tinting (matching iPhone)
 */
class WebRtcTextureView(context: Context) : TextureView(context), TextureView.SurfaceTextureListener, VideoSink {

    private val eglRenderer = EglRenderer("KKRemoteTextureRenderer")
    private val glDrawer = HdrAwareGlDrawer()
    private val initialized = AtomicBoolean(false)
    private var boundTrack: VideoTrack? = null

    @Volatile
    private var lastWidth = 0

    @Volatile
    private var lastHeight = 0

    private val sampleW = 160
    private val sampleH = 120
    private val sampleBuffers = arrayOf(
        Bitmap.createBitmap(sampleW, sampleH, Bitmap.Config.ARGB_8888),
        Bitmap.createBitmap(sampleW, sampleH, Bitmap.Config.ARGB_8888),
    )
    private var bufferToggle = 0
    private var sampleGeneration = 0L
    private var lastSampleUptimeMs = 0L
    private val edgeStripPixels = IntArray(136)
    private val edgeEstimator = WindowEdgeColorEstimator()

    var onVideoDimensionsChanged: ((Int, Int) -> Unit)? = null
    var onBackdropSampled: ((ImageBitmap, WindowEdgeColor?, Long) -> Unit)? = null

    init {
        isOpaque = false
        surfaceTextureListener = this
        ensureRendererInitialized()
    }

    private fun ensureRendererInitialized() {
        if (initialized.compareAndSet(false, true)) {
            eglRenderer.init(WebRtcRuntime.eglBase.eglBaseContext, EglBase.CONFIG_PLAIN, glDrawer)
        }
    }

    fun setHdrPqMode(enabled: Boolean) {
        glDrawer.setHdrPqEnabled(enabled)
    }

    fun bindTrack(track: VideoTrack?) {
        if (boundTrack === track) return
        runCatching { boundTrack?.removeSink(this) }
        boundTrack = track
        if (track != null) {
            ensureRendererInitialized()
            runCatching { track.addSink(this) }
        }
    }

    override fun onFrame(frame: VideoFrame?) {
        if (frame == null) return
        val w = frame.rotatedWidth
        val h = frame.rotatedHeight
        if (w > 0 && h > 0 && (w != lastWidth || h != lastHeight)) {
            lastWidth = w
            lastHeight = h
            post { onVideoDimensionsChanged?.invoke(w, h) }
        }
        if (initialized.get()) {
            eglRenderer.onFrame(frame)
        }
    }

    override fun onSurfaceTextureAvailable(surface: SurfaceTexture, width: Int, height: Int) {
        ensureRendererInitialized()
        eglRenderer.createEglSurface(surface)
    }

    override fun onSurfaceTextureSizeChanged(surface: SurfaceTexture, width: Int, height: Int) {}

    override fun onSurfaceTextureDestroyed(surface: SurfaceTexture): Boolean {
        if (initialized.get()) {
            val latch = CountDownLatch(1)
            eglRenderer.releaseEglSurface { latch.countDown() }
            runCatching { latch.await(600, TimeUnit.MILLISECONDS) }
        }
        return true
    }

    override fun onSurfaceTextureUpdated(surface: SurfaceTexture) {
        val listener = onBackdropSampled ?: return
        val now = SystemClock.uptimeMillis()
        if (now - lastSampleUptimeMs < 140L || !isAvailable || width <= 0 || height <= 0) return
        lastSampleUptimeMs = now

        val targetBitmap = sampleBuffers[bufferToggle]
        bufferToggle = 1 - bufferToggle
        val captured = runCatching { getBitmap(targetBitmap) }.getOrNull() ?: return

        // Sample inside the Mac window's top titlebar fill (skipping the 1-2px bright rim)
        targetBitmap.getPixels(edgeStripPixels, 0, edgeStripPixels.size, 12, 3, edgeStripPixels.size, 1)
        val newEdgeColor = edgeEstimator.consumeArgbPixels(edgeStripPixels)
        sampleGeneration += 1L
        listener(captured.asImageBitmap(), newEdgeColor, sampleGeneration)
    }

    override fun onDetachedFromWindow() {
        runCatching { boundTrack?.removeSink(this) }
        boundTrack = null
        if (initialized.compareAndSet(true, false)) {
            runCatching { eglRenderer.release() }
        }
        super.onDetachedFromWindow()
    }
}
