package com.vinhhoang.docsnap.ui.common

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp

/** Dims the screen and blocks taps while a long job (saving, making a PDF) runs. */
@Composable
fun BusyOverlay(message: String, modifier: Modifier = Modifier) {
    Box(
        modifier
            .fillMaxSize()
            .background(Color.Black.copy(alpha = 0.35f))
            // Swallow taps so nothing underneath is pressed twice.
            .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) {}
            .testTag("busyOverlay"),
        contentAlignment = Alignment.Center,
    ) {
        Surface(shape = RoundedCornerShape(20.dp), tonalElevation = 6.dp, shadowElevation = 6.dp) {
            Column(
                Modifier.padding(horizontal = 32.dp, vertical = 24.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                CircularProgressIndicator()
                Text(
                    message,
                    style = MaterialTheme.typography.titleMedium,
                    modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite },
                )
            }
        }
    }
}

/** A small non-blocking "Applying…" pill for quick edits. */
@Composable
fun BusyPill(message: String, modifier: Modifier = Modifier) {
    Surface(
        modifier = modifier.testTag("busyPill"),
        shape = RoundedCornerShape(50),
        color = MaterialTheme.colorScheme.inverseSurface,
        contentColor = MaterialTheme.colorScheme.inverseOnSurface,
        shadowElevation = 4.dp,
    ) {
        Row(
            Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            CircularProgressIndicator(
                modifier = Modifier.size(16.dp),
                strokeWidth = 2.dp,
                color = MaterialTheme.colorScheme.inverseOnSurface,
            )
            Text(message, style = MaterialTheme.typography.labelLarge)
        }
    }
}
