package com.kkremote.android.ui

import androidx.compose.ui.graphics.Color
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.pow

/**
 * Ported from iOS WindowEdgeColor.swift.
 * Estimates the remote Mac window's titlebar fill color using a dominant-bucket histogram
 * (rejecting text/traffic-light icons) with 2-frame debounce confirmation.
 */
data class WindowEdgeColor(
    val red: Float,
    val green: Float,
    val blue: Float,
) {
    val composeColor: Color
        get() = Color(
            red = red.coerceIn(0f, 1f),
            green = green.coerceIn(0f, 1f),
            blue = blue.coerceIn(0f, 1f),
            alpha = 1f,
        )

    /** True when the sampled backdrop is dark (relative luminance < 0.18), preferring light foreground text/icons. */
    val prefersLightContent: Boolean
        get() {
            fun linear(v: Float): Double {
                val d = v.coerceIn(0f, 1f).toDouble()
                return if (d <= 0.04045) d / 12.92 else ((d + 0.055) / 1.055).pow(2.4)
            }
            val lum = 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
            return lum < 0.18
        }

    fun distanceTo(other: WindowEdgeColor): Float =
        max(abs(red - other.red), max(abs(green - other.green), abs(blue - other.blue)))

    companion object {
        val Initial = WindowEdgeColor(0.94f, 0.94f, 0.95f)
    }
}

class WindowEdgeColorEstimator {
    var current: WindowEdgeColor? = null
        private set
    private var pending: WindowEdgeColor? = null
    private var confirmations: Int = 0

    /** Consumes packed ARGB_8888 pixels sampled along the visible top strip of the remote window. */
    fun consumeArgbPixels(argbPixels: IntArray): WindowEdgeColor? {
        if (argbPixels.size < 4) return null

        class Bucket(var count: Int = 0, var rSum: Int = 0, var gSum: Int = 0, var bSum: Int = 0)
        val buckets = HashMap<Int, Bucket>(32)
        var valid = 0

        for (px in argbPixels) {
            val a = (px ushr 24) and 0xff
            if (a < 240) continue
            val r = (px ushr 16) and 0xff
            val g = (px ushr 8) and 0xff
            val b = px and 0xff
            val key = ((r ushr 4) shl 8) or ((g ushr 4) shl 4) or (b ushr 4)
            val bucket = buckets.getOrPut(key) { Bucket() }
            bucket.count += 1
            bucket.rSum += r
            bucket.gSum += g
            bucket.bSum += b
            valid += 1
        }

        val winner = buckets.values.maxByOrNull { it.count }
        if (valid < 4 || winner == null || winner.count.toFloat() / valid.toFloat() < 0.35f) {
            pending = null
            confirmations = 0
            return null
        }

        val denom = winner.count * 255f
        val candidate = WindowEdgeColor(
            red = winner.rSum / denom,
            green = winner.gSum / denom,
            blue = winner.bSum / denom,
        )

        val cur = current
        if (cur != null) {
            if (cur.distanceTo(candidate) <= 3f / 255f) {
                pending = null
                confirmations = 0
                return null
            }
            val pend = pending
            if (pend != null && pend.distanceTo(candidate) < 8f / 255f) {
                confirmations += 1
            } else {
                pending = candidate
                confirmations = 1
            }
            if (confirmations < 2) return null
        }

        current = candidate
        pending = null
        confirmations = 0
        return candidate
    }
}
