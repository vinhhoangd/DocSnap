package com.vinhhoang.docsnap.ui.common

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

class ImageSamplingTest {
    @Test fun smallImageIsNotSampled() {
        assertEquals(1, ImageSampling.inSampleSize(400, 600, 600))
        assertEquals(1, ImageSampling.inSampleSize(100, 100, 600))
    }

    @Test fun twelveMegapixelThumbnail() {
        // 3024×4032 → sample 4 gives 1008 px longest side (≥ 600); 8 would give 504 (< 600).
        assertEquals(4, ImageSampling.inSampleSize(3024, 4032, 600))
    }

    @Test fun viewerSizeKeepsDetail() {
        assertEquals(1, ImageSampling.inSampleSize(3024, 4032, 2560))
        assertEquals(2, ImageSampling.inSampleSize(4096, 5461, 2560))
    }

    @Test fun exactlyDoubleSamplesByTwo() {
        assertEquals(2, ImageSampling.inSampleSize(1200, 800, 600))
        assertEquals(1, ImageSampling.inSampleSize(1199, 800, 600))
    }

    @Test fun landscapeUsesLongestSide() {
        assertEquals(ImageSampling.inSampleSize(3000, 2000, 500), ImageSampling.inSampleSize(2000, 3000, 500))
    }

    @Test fun decodedSideNeverDropsBelowTarget() {
        for (side in listOf(601, 999, 1500, 2400, 4096, 8000)) {
            val sample = ImageSampling.inSampleSize(side, side / 2, 600)
            assertEquals("side=$side", true, side / sample >= 600)
            assertEquals("side=$side", true, side / (sample * 2) < 600)
        }
    }

    @Test fun badSizesFallBackToOne() {
        assertEquals(1, ImageSampling.inSampleSize(0, 100, 600))
        assertEquals(1, ImageSampling.inSampleSize(100, -1, 600))
        assertEquals(1, ImageSampling.inSampleSize(4000, 3000, 0))
    }

    @Test fun cacheKeyChangesWithVersionAndSize() {
        val a = ImageSampling.cacheKey("/x/p.jpg", 0, 600)
        assertNotEquals(a, ImageSampling.cacheKey("/x/p.jpg", 1, 600))
        assertNotEquals(a, ImageSampling.cacheKey("/x/p.jpg", 0, 2560))
        assertNotEquals(a, ImageSampling.cacheKey("/y/p.jpg", 0, 600))
        assertEquals(a, ImageSampling.cacheKey("/x/p.jpg", 0, 600))
    }
}
