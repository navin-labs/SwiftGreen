package com.swiftgreen.app.ui.theme

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

// ponytail: one scheme, no light variant, no Material You. Dynamic colour would
// pull the user's wallpaper hue into ripples, badges and button defaults, which
// is the one thing a strictly monochrome app cannot allow.
private val MonochromeScheme = darkColorScheme(
    primary = Purple80,
    onPrimary = Color(0xFF000000),
    secondary = PurpleGrey80,
    tertiary = Pink80,
    background = Color(0xFF000000),
    onBackground = Color(0xFFFFFFFF),
    surface = Color(0xFF1A1A1A),
    onSurface = Color(0xFFFFFFFF),
    surfaceVariant = Color(0xFF2A2A2A),
    onSurfaceVariant = Color(0x99FFFFFF),
    outline = Color(0x66FFFFFF),
    error = Color(0xFFFFFFFF),
    onError = Color(0xFF000000)
)

@Composable
fun SwiftGreenTheme(
    content: @Composable () -> Unit
) {
    MaterialTheme(
        colorScheme = MonochromeScheme,
        typography = Typography,
        content = content
    )
}