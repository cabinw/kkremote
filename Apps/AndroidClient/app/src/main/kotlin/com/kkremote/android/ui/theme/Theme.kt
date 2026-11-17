package com.kkremote.android.ui.theme

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable

private val KKRemoteDarkColors = darkColorScheme(
    primary = ElectricAccent,
    onPrimary = StudioCanvas,
    primaryContainer = ElectricAccentDim,
    onPrimaryContainer = TextPrimary,
    secondary = EmeraldLive,
    background = StudioCanvas,
    onBackground = TextPrimary,
    surface = StudioSurface,
    onSurface = TextPrimary,
    surfaceVariant = StudioSurfaceElevated,
    onSurfaceVariant = TextSecondary,
    outline = StudioBorder,
    error = CoralAlert,
)

@Composable
fun KKRemoteTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = KKRemoteDarkColors,
        typography = Typography,
        content = content,
    )
}
