package com.vinhhoang.docsnap.ui.page

import androidx.compose.ui.geometry.Offset
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ZoomMathTest {
    @Test fun scaleIsClamped() {
        assertEquals(1f, ZoomMath.clampScale(0.3f))
        assertEquals(5f, ZoomMath.clampScale(9f))
        assertEquals(2f, ZoomMath.clampScale(2f))
    }

    @Test fun nearlyOneIsNotZoomed() {
        assertFalse(ZoomMath.isZoomed(1f))
        assertFalse(ZoomMath.isZoomed(1.005f))
        assertTrue(ZoomMath.isZoomed(1.2f))
    }

    @Test fun atOneTheresNoRoomToPan() {
        assertEquals(Offset.Zero, ZoomMath.clampOffset(Offset(50f, -80f), 1f, 1000, 2000))
    }

    @Test fun panIsLimitedToTheOverflow() {
        // At 2× a 1000×2000 frame overflows by 500 / 1000 px on each side.
        assertEquals(Offset(500f, -1000f), ZoomMath.clampOffset(Offset(900f, -5000f), 2f, 1000, 2000))
        assertEquals(Offset(-200f, 300f), ZoomMath.clampOffset(Offset(-200f, 300f), 2f, 1000, 2000))
    }

    @Test fun doubleTapAtCenterStaysCentered() {
        assertEquals(Offset.Zero, ZoomMath.offsetForDoubleTap(Offset(500f, 1000f), 2.5f, 1000, 2000))
    }

    @Test fun doubleTapNearCornerKeepsCornerInFrame() {
        val offset = ZoomMath.offsetForDoubleTap(Offset(0f, 0f), 2.5f, 1000, 2000)
        // Max overflow at 2.5×: 750 / 1500 px.
        assertEquals(Offset(750f, 1500f), offset)
    }

    @Test fun doubleTapKeepsTappedPointUnderFinger() {
        val tap = Offset(600f, 1100f)
        val scale = 2.5f
        val offset = ZoomMath.offsetForDoubleTap(tap, scale, 1000, 2000)
        // graphicsLayer scales around the centre, then translates.
        val center = Offset(500f, 1000f)
        val shown = center + (tap - center) * scale + offset
        assertEquals(tap.x, shown.x, 0.01f)
        assertEquals(tap.y, shown.y, 0.01f)
    }
}
