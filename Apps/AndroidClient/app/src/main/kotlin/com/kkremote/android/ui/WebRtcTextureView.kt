package com.kkremote.android.ui

import android.content.Context
import android.graphics.SurfaceTexture
import android.view.TextureView
import com.kkremote.android.webrtc.WebRtcRuntime
import org.webrtc.EglBase
import org.webrtc.EglRenderer
import org.webrtc.GlRectDrawer
import org.webrtc.VideoFrame
import org.webrtc.VideoSink
import org.webrtc.VideoTrack
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Hardware-accelerated OpenGL ES TextureView backed by WebRTC's EglRenderer.
 * Unlike SurfaceViewRenderer, TextureView participates cleanly in Compose graphicsLayer
 * zoom/pan transforms, rounded clip masks, floating glass controls, and ADB screenshots.
 */
class WebRtcTextureView(context: Context) : TextureView(context), TextureView.SurfaceTextureListener, VideoSink {

    private val eglRenderer = EglRenderer("KKRemoteTextureRenderer")
    private val initialized = AtomicBoolean(false)
    private var boundTrack: VideoTrack? = null

    @Volatile
    private var lastWidth = 0

    @Volatile
    private var lastHeight = 0

    var onVideoDimensionsChanged: ((Int, Int) -> Unit)? = null

    init {
        isOpaque = false
        surfaceTextureListener = this
        ensureRendererInitialized()
    }

    private fun ensureRendererInitialized() {
        if (initialized.compareAndSet(false, true)) {
            eglRenderer.init(WebRtcRuntime.eglBase.eglBaseContext, EglBase.CONFIG_PLAIN, GlRectDrawer())
        }
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

    override fun onSurfaceTextureSizeChanged(surface: SurfaceTexture, width: Int, height: Int) {
        // EglRenderer queries current EGL surface dimensions dynamically on each rendered frame.
    }

    override fun onSurfaceTextureDestroyed(surface: SurfaceTexture): Boolean {
        if (initialized.get()) {
            val latch = CountDownLatch(1)
            eglRenderer.releaseEglSurface { latch.countDown() }
            runCatching { latch.await(600, TimeUnit.MILLISECONDS) }
        }
        return true
    }

    override fun onSurfaceTextureUpdated(surface: SurfaceTexture) {}

    override fun onDetachedFromWindow() {
        runCatching { boundTrack?.removeSink(this) }
        boundTrack = null
        if (initialized.compareAndSet(true, false)) {
            runCatching { eglRenderer.release() }
        }
        super.onDetachedFromWindow()
    }
}
