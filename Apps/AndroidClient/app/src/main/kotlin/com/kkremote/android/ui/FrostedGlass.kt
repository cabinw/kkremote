package com.kkremote.android.ui

import android.os.Build
import android.view.WindowManager
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.BlurredEdgeTreatment
import androidx.compose.ui.draw.blur
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.ColorMatrix
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.compose.ui.window.DialogWindowProvider
import kotlin.math.roundToInt

/**
 * Apple iOS .regularMaterial / .thinMaterial optical tokens, automatically adapting
 * to whether the active Mac window backdrop is light or dark.
 */
data class GlassPalette(
    val isDark: Boolean,
    val surfaceTint: Color,
    val elevatedCardTint: Color,
    val specularTop: Color,
    val specularBottom: Color,
    val hairlineBorder: Color,
    val dividerColor: Color,
    val primaryText: Color,
    val secondaryText: Color,
    val accentBlue: Color,
    val destructiveRed: Color,
) {
    companion object {
        fun forDarkMode(isDark: Boolean): GlassPalette = if (isDark) {
            GlassPalette(
                isDark = true,
                surfaceTint = Color(0xFF22242C).copy(alpha = 0.66f),
                elevatedCardTint = Color(0xFF2C2F3A).copy(alpha = 0.56f),
                specularTop = Color.White.copy(alpha = 0.14f),
                specularBottom = Color.White.copy(alpha = 0.03f),
                hairlineBorder = Color.White.copy(alpha = 0.16f),
                dividerColor = Color.White.copy(alpha = 0.11f),
                primaryText = Color(0xFFF5F6FA),
                secondaryText = Color(0xFFA2A8B8),
                accentBlue = Color(0xFF0A84FF),
                destructiveRed = Color(0xFFFF453A),
            )
        } else {
            GlassPalette(
                isDark = false,
                surfaceTint = Color(0xFFF7F8FC).copy(alpha = 0.68f),
                elevatedCardTint = Color.White.copy(alpha = 0.62f),
                specularTop = Color.White.copy(alpha = 0.62f),
                specularBottom = Color.White.copy(alpha = 0.18f),
                hairlineBorder = Color.Black.copy(alpha = 0.09f),
                dividerColor = Color.Black.copy(alpha = 0.09f),
                primaryText = Color(0xFF14161C),
                secondaryText = Color(0xFF5E6472),
                accentBlue = Color(0xFF007AFF),
                destructiveRed = Color(0xFFFF3B30),
            )
        }
    }
}

/**
 * Live backdrop state sampled from the full-screen canvas + WebRtcTextureView so floating
 * capsules, menus, and bars display genuine blurred & vibrancy-boosted live pixels underneath.
 */
data class LiveVideoBackdrop(
    val videoBitmap: ImageBitmap? = null,
    val videoRectInRoot: Rect = Rect.Zero,
    val ambientColor: Color = WindowEdgeColor.Initial.composeColor,
    val generation: Long = 0L,
)

private val VibrancyMatrix = ColorMatrix().apply { setToSaturation(1.38f) }

/**
 * iOS-style Frosted Glass container (.regularMaterial) with real live video backdrop blur,
 * saturation vibrancy boost, vertical specular sheen, and 0.5dp hairline border.
 */
@Composable
fun FrostedGlassBox(
    palette: GlassPalette,
    backdrop: LiveVideoBackdrop,
    shape: Shape,
    modifier: Modifier = Modifier,
    blurRadius: Dp = 32.dp,
    shadowElevation: Dp = 14.dp,
    contentAlignment: Alignment = Alignment.TopStart,
    content: @Composable BoxScope.() -> Unit,
) {
    var boxBoundsInRoot by remember { mutableStateOf(Rect.Zero) }

    Box(
        contentAlignment = contentAlignment,
        modifier = modifier
            .onGloballyPositioned { coords ->
                boxBoundsInRoot = coords.boundsInRoot()
            }
            .shadow(
                elevation = shadowElevation,
                shape = shape,
                ambientColor = Color.Black.copy(alpha = 0.18f),
                spotColor = Color.Black.copy(alpha = 0.20f),
            )
            .clip(shape)
            .border(BorderStroke(0.6.dp, palette.hairlineBorder), shape),
    ) {
        // Optical Layer 1: Clamped (Rectangle) Gaussian blur keeps alpha = 1.0 all the way to edges
        // so sharp unblurred TextureView text underneath can never bleed through thin capsules!
        Canvas(
            modifier = Modifier
                .matchParentSize()
                .blur(radius = blurRadius, edgeTreatment = BlurredEdgeTreatment.Rectangle),
        ) {
            val gen = backdrop.generation
            if (gen >= 0L) {
                drawRect(color = backdrop.ambientColor)
            }
            val bmp = backdrop.videoBitmap
            val vRect = backdrop.videoRectInRoot
            if (bmp != null && vRect.width > 1f && vRect.height > 1f && boxBoundsInRoot.width > 1f) {
                val dstLeft = (vRect.left - boxBoundsInRoot.left).roundToInt()
                val dstTop = (vRect.top - boxBoundsInRoot.top).roundToInt()
                drawImage(
                    image = bmp,
                    dstOffset = IntOffset(dstLeft, dstTop),
                    dstSize = IntSize(vRect.width.roundToInt(), vRect.height.roundToInt()),
                    colorFilter = ColorFilter.colorMatrix(VibrancyMatrix),
                )
            }
        }

        // Optical Layer 2: Apple .regularMaterial translucent tint + subtle specular gradient
        Box(
            modifier = Modifier
                .matchParentSize()
                .background(palette.surfaceTint)
                .background(
                    Brush.verticalGradient(
                        colors = listOf(palette.specularTop, palette.specularBottom),
                    )
                ),
        )

        // Foreground crisp content (unblurred)
        content()
    }
}

/**
 * Frosted Glass Modal Sheet / Card Dialog that activates Android 12–17 hardware SurfaceFlinger
 * window backdrop blur (FLAG_BLUR_BEHIND) and centers cleanly on wide foldable displays.
 */
@Composable
fun FrostedModalSheet(
    palette: GlassPalette,
    backdrop: LiveVideoBackdrop,
    onDismiss: () -> Unit,
    maxWidth: Dp = 520.dp,
    content: @Composable BoxScope.() -> Unit,
) {
    Dialog(
        onDismissRequest = onDismiss,
        properties = DialogProperties(
            usePlatformDefaultWidth = false,
            decorFitsSystemWindows = false,
        ),
    ) {
        val dialogWindow = (LocalView.current.parent as? DialogWindowProvider)?.window
        DisposableEffect(dialogWindow) {
            if (dialogWindow != null) {
                dialogWindow.setDimAmount(if (palette.isDark) 0.28f else 0.16f)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    dialogWindow.addFlags(WindowManager.LayoutParams.FLAG_BLUR_BEHIND)
                    val attrs = dialogWindow.attributes
                    attrs.blurBehindRadius = 56
                    dialogWindow.attributes = attrs
                }
            }
            onDispose {}
        }

        Box(
            modifier = Modifier
                .fillMaxSize()
                .clickable(
                    interactionSource = remember { MutableInteractionSource() },
                    indication = null,
                    onClick = onDismiss,
                )
                .imePadding()
                .padding(horizontal = 16.dp, vertical = 28.dp),
            contentAlignment = Alignment.Center,
        ) {
            FrostedGlassBox(
                palette = palette,
                backdrop = backdrop,
                shape = RoundedCornerShape(26.dp),
                blurRadius = 30.dp,
                shadowElevation = 24.dp,
                modifier = Modifier
                    .widthIn(max = maxWidth)
                    .clickable(
                        interactionSource = remember { MutableInteractionSource() },
                        indication = null,
                        onClick = {},
                    ),
                content = content,
            )
        }
    }
}
