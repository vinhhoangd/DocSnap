package com.vinhhoang.docsnap.ui.common

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ImageSamplingTest {
    private val mb = 1024L * 1024L

    /** BitmapFactory's decoded side for a sample size (it rounds partial pixels up). */
    private fun decoded(side: Int, sample: Int) = (side + sample - 1) / sample

    @Test fun smallImageIsNotSampled() {
        assertEquals(1, ImageSampling.inSampleSize(400, 600, 600))
        assertEquals(1, ImageSampling.inSampleSize(100, 100, 600))
    }

    @Test fun twelveMegapixelThumbnail() {
        // 3024×4032 → sample 8 gives 504 px (≤ 600); 4 would give 1008 (too big).
        assertEquals(8, ImageSampling.inSampleSize(3024, 4032, 600))
    }

    @Test fun viewerNeverDecodesAFullSizePage() {
        // The bug: a 4096 px page was decoded at sample 1 (a 50 MB bitmap) for a 2560 px viewer.
        assertEquals(2, ImageSampling.inSampleSize(3072, 4096, 2560))
        assertEquals(2, ImageSampling.inSampleSize(3024, 4032, 2560))
        assertEquals(4, ImageSampling.inSampleSize(4096, 5461, 2560))
    }

    @Test fun exactlyMaxSideIsNotSampled() {
        assertEquals(1, ImageSampling.inSampleSize(600, 400, 600))
        assertEquals(2, ImageSampling.inSampleSize(601, 400, 600))
    }

    @Test fun landscapeUsesLongestSide() {
        assertEquals(ImageSampling.inSampleSize(3000, 2000, 500), ImageSampling.inSampleSize(2000, 3000, 500))
    }

    @Test fun decodedSideNeverExceedsTargetAndIsTheLargestSuch() {
        for (maxSide in listOf(480, 600, 2048, 2560)) {
            for (side in listOf(1, 479, 601, 999, 1500, 2400, 2561, 4096, 5461, 8000, 12000)) {
                val sample = ImageSampling.inSampleSize(side, side / 2 + 1, maxSide)
                assertTrue("side=$side max=$maxSide", decoded(side, sample) <= maxSide)
                if (sample > 1) assertTrue("side=$side max=$maxSide", decoded(side, sample / 2) > maxSide)
            }
        }
    }

    @Test fun badSizesFallBackToOne() {
        assertEquals(1, ImageSampling.inSampleSize(0, 100, 600))
        assertEquals(1, ImageSampling.inSampleSize(100, -1, 600))
        assertEquals(1, ImageSampling.inSampleSize(4000, 3000, 0))
    }

    @Test fun targetSizeFitsLongestSideAndKeepsAspect() {
        assertEquals(1920 to 2560, ImageSampling.targetSize(3072, 4096, 2560))
        assertEquals(2560 to 1920, ImageSampling.targetSize(4096, 3072, 2560))
        val (w, h) = ImageSampling.targetSize(3024, 4032, 2560)
        assertEquals(2560, h)
        assertEquals(1920, w)
    }

    @Test fun targetSizeNeverUpscalesOrReturnsZero() {
        assertEquals(800 to 600, ImageSampling.targetSize(800, 600, 2560))
        assertEquals(1 to 2560, ImageSampling.targetSize(1, 5000, 2560))
        assertEquals(1 to 1, ImageSampling.targetSize(0, 0, 2560))
    }

    @Test fun viewerBitmapStaysWellUnderFiftyMegabytes() {
        for (maxSide in listOf(ImageSampling.viewerMaxSide(192 * mb), ImageSampling.viewerMaxSide(512 * mb))) {
            val (w, h) = ImageSampling.targetSize(3072, 4096, maxSide)
            assertTrue(ImageSampling.argbBytes(w, h) <= 20 * mb)
        }
    }

    @Test fun smallHeapGetsASmallerViewerSize() {
        assertEquals(2048, ImageSampling.viewerMaxSide(192 * mb))
        assertEquals(2048, ImageSampling.viewerMaxSide(256 * mb))
        assertEquals(2560, ImageSampling.viewerMaxSide(512 * mb))
    }

    @Test fun cacheIsASixthOfTheHeapWithinBounds() {
        assertEquals(32 * mb, ImageSampling.cacheBytes(192 * mb))
        assertEquals(64 * mb, ImageSampling.cacheBytes(512 * mb))
        assertEquals(4 * mb, ImageSampling.cacheBytes(16 * mb))
    }

    @Test fun fullPagesOnALowRamPhoneAreNotCached() {
        val cache = ImageSampling.cacheBytes(256 * mb)
        // A 2048 px viewer page (12 MB) would push out most thumbnails: not cached.
        val (w, h) = ImageSampling.targetSize(3072, 4096, ImageSampling.viewerMaxSide(256 * mb))
        assertFalse(ImageSampling.fitsCache(ImageSampling.argbBytes(w, h), cache))
        // A 480 px thumbnail is.
        val (tw, th) = ImageSampling.targetSize(3072, 4096, 480)
        assertTrue(ImageSampling.fitsCache(ImageSampling.argbBytes(tw, th), cache))
    }

    @Test fun fitsCacheBoundary() {
        assertTrue(ImageSampling.fitsCache(25, 100))
        assertFalse(ImageSampling.fitsCache(26, 100))
        assertFalse(ImageSampling.fitsCache(0, 100))
    }

    @Test fun cacheKeyChangesWithVersionAndSize() {
        val a = ImageSampling.cacheKey("/x/p.jpg", 0, 600)
        assertNotEquals(a, ImageSampling.cacheKey("/x/p.jpg", 1, 600))
        assertNotEquals(a, ImageSampling.cacheKey("/x/p.jpg", 0, 2560))
        assertNotEquals(a, ImageSampling.cacheKey("/y/p.jpg", 0, 600))
        assertEquals(a, ImageSampling.cacheKey("/x/p.jpg", 0, 600))
    }
}
