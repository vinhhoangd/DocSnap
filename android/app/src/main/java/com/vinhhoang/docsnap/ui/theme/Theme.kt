package com.vinhhoang.docsnap.ui.theme

import android.os.Build
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import com.vinhhoang.docsnap.data.Appearance

/** DocSnap "scan blue", same as the iPhone app (#2563EB light, #3B82F6 dark). */
val ScanBlue = Color(0xFF2563EB)
val ScanBlueDark = Color(0xFF3B82F6)

private val Light = lightColorScheme(
    primary = ScanBlue,
    onPrimary = Color.White,
    primaryContainer = Color(0xFFDBE7FE),
    onPrimaryContainer = Color(0xFF0B2A6B),
    background = Color(0xFFF6F7F9),
    surface = Color.White,
    surfaceVariant = Color(0xFFEFF1F4),
)

private val Dark = darkColorScheme(
    primary = ScanBlueDark,
    onPrimary = Color.White,
    primaryContainer = Color(0xFF1E3A8A),
    onPrimaryContainer = Color(0xFFDBE7FE),
    background = Color(0xFF0E0F12),
    surface = Color(0xFF17191D),
    surfaceVariant = Color(0xFF22252B),
)

@Composable
fun DocSnapTheme(appearance: Appearance = Appearance.System, content: @Composable () -> Unit) {
    val dark = when (appearance) {
        Appearance.System -> isSystemInDarkTheme()
        Appearance.Light -> false
        Appearance.Dark -> true
    }
    MaterialTheme(colorScheme = if (dark) Dark else Light, content = content)
}

/** Android 13+ shows its own "copied" toast; older versions need ours. */
val showsOwnCopyToast: Boolean get() = Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU
