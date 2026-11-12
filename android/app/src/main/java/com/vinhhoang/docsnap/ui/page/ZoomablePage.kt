package com.vinhhoang.docsnap.ui.page

import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.calculatePan
import androidx.compose.foundation.gestures.calculateZoom
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChanged

/** Zoom limits and the pan bounds that keep a zoomed page covering its frame (pure math, unit-tested). */
object ZoomMath {
    const val MIN_SCALE = 1f
    const val MAX_SCALE = 5f
    const val DOUBLE_TAP_SCALE = 2.5f

    fun isZoomed(scale: Float) = scale > 1.01f

    fun clampScale(scale: Float) = scale.coerceIn(MIN_SCALE, MAX_SCALE)

    /** Clamps an offset (from the centre) so the scaled content never shows a gap at the edges. */
    fun clampOffset(offset: Offset, scale: Float, width: Int, height: Int): Offset {
        if (scale <= 1f) return Offset.Zero
        val maxX = width * (scale - 1f) / 2f
        val maxY = height * (scale - 1f) / 2f
        return Offset(offset.x.coerceIn(-maxX, maxX), offset.y.coerceIn(-maxY, maxY))
    }

    /** Offset that keeps `tap` under the finger when zooming from 1× to `scale` on a double tap. */
    fun offsetForDoubleTap(tap: Offset, scale: Float, width: Int, height: Int): Offset {
        val center = Offset(width / 2f, height / 2f)
        return clampOffset((center - tap) * (scale - 1f), scale, width, height)
    }
}

/**
 * Pinch to zoom, drag to pan when zoomed, double-tap to zoom in/out. One-finger drags at 1× are left
 * alone so the pager can swipe to the next page; while zoomed the caller turns pager swiping off.
 */
@Composable
fun ZoomablePage(
    isCurrent: Boolean,
    onZoomedChange: (Boolean) -> Unit,
    modifier: Modifier = Modifier,
    content: @Composable () -> Unit,
) {
    var scale by remember { mutableFloatStateOf(1f) }
    var offset by remember { mutableStateOf(Offset.Zero) }
    val currentOnZoomedChange by rememberUpdatedState(onZoomedChange)
    val zoomed = ZoomMath.isZoomed(scale)

    LaunchedEffect(isCurrent) {
        if (!isCurrent) {
            scale = 1f
            offset = Offset.Zero
        }
    }
    LaunchedEffect(zoomed, isCurrent) { if (isCurrent) currentOnZoomedChange(zoomed) }

    Box(
        modifier
            .fillMaxSize()
            .clipToBounds()
            .pointerInput(Unit) {
                detectTapGestures(onDoubleTap = { tap ->
                    if (ZoomMath.isZoomed(scale)) {
                        scale = 1f
                        offset = Offset.Zero
                    } else {
                        scale = ZoomMath.DOUBLE_TAP_SCALE
                        offset = ZoomMath.offsetForDoubleTap(tap, scale, this.size.width, this.size.height)
                    }
                })
            }
            .pointerInput(Unit) {
                awaitEachGesture {
                    awaitFirstDown(requireUnconsumed = false)
                    do {
                        val event = awaitPointerEvent()
                        val fingers = event.changes.count { it.pressed }
                        if (fingers >= 2 || ZoomMath.isZoomed(scale)) {
                            val newScale = ZoomMath.clampScale(scale * event.calculateZoom())
                            offset = if (ZoomMath.isZoomed(newScale)) {
                                ZoomMath.clampOffset(offset + event.calculatePan(), newScale, this.size.width, this.size.height)
                            } else {
                                Offset.Zero
                            }
                            scale = newScale
                            event.changes.forEach { if (it.positionChanged()) it.consume() }
                        }
                    } while (event.changes.any { it.pressed })
                    if (!ZoomMath.isZoomed(scale)) {
                        scale = 1f
                        offset = Offset.Zero
                    }
                }
            },
    ) {
        Box(
            Modifier
                .fillMaxSize()
                .graphicsLayer {
                    scaleX = scale
                    scaleY = scale
                    translationX = offset.x
                    translationY = offset.y
                },
        ) { content() }
    }
}
