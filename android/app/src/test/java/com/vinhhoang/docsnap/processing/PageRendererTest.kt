package com.vinhhoang.docsnap.processing

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.io.IOException

/** The renderer's pure helpers (decoding itself needs Android, which these JVM tests don't have). */
class PageRendererTest {
    @get:Rule val temp = TemporaryFolder()

    @Test fun sampleSizeKeepsDetail() {
        assertEquals(1, PageRenderer.sampleSize(4032, 3024, 4096)) // iPhone / Samsung 12 MP
        assertEquals(1, PageRenderer.sampleSize(3024, 4032, 4096))
        assertEquals(1, PageRenderer.sampleSize(100, 100, 4096))
        assertEquals(1, PageRenderer.sampleSize(6000, 4500, 4096)) // 3000 would be < 3072
        assertEquals(2, PageRenderer.sampleSize(8160, 6120, 4096)) // 50 MP → 4080
        assertEquals(4, PageRenderer.sampleSize(16320, 12240, 4096)) // 200 MP → 4080
        assertEquals(1, PageRenderer.sampleSize(0, 0, 4096))
        assertEquals(2, PageRenderer.sampleSize(4096, 100, 2048))
    }

    @Test fun sampledImageIsNeverBelowThreeQuartersOfTheCap() {
        for (longest in listOf(3072, 4095, 4096, 6143, 6144, 8191, 8192, 12000, 20000, 40000)) {
            val s = PageRenderer.sampleSize(longest, 10, 4096)
            assertTrue("$longest / $s", longest / s >= 3072 || s == 1)
            assertTrue("$longest / ${s * 2} would also do", longest / (s * 2) < 3072)
        }
    }

    @Test fun fittedSizeCapsTheLongestSide() {
        assertEquals(4032 to 3024, PageRenderer.fittedSize(4032, 3024, 4096))
        assertEquals(4096 to 3072, PageRenderer.fittedSize(6000, 4500, 4096))
        assertEquals(3072 to 4096, PageRenderer.fittedSize(4500, 6000, 4096))
        assertEquals(4096 to 1, PageRenderer.fittedSize(9000, 1, 4096))
        assertEquals(1 to 1, PageRenderer.fittedSize(1, 1, 4096))
    }

    @Test fun recognisesJpegFiles() {
        val jpeg = temp.newFile("a.jpg").apply { writeBytes(byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 0xFF.toByte(), 0xE0.toByte())) }
        val png = temp.newFile("b.jpg").apply { writeBytes(byteArrayOf(0x89.toByte(), 0x50, 0x4E, 0x47)) }
        val empty = temp.newFile("c.jpg")
        assertTrue(PageRenderer.isJpeg(jpeg))
        assertFalse(PageRenderer.isJpeg(png))
        assertFalse(PageRenderer.isJpeg(empty))
        assertFalse(PageRenderer.isJpeg(File(temp.root, "missing.jpg")))
    }

    @Test fun writeAtomicallyReplacesTheFileAndLeavesNoTemp() {
        val out = File(temp.root, "processed/page.jpg")
        PageRenderer.writeAtomically(out) { it.writeText("one") }
        PageRenderer.writeAtomically(out) { it.writeText("two") }
        assertEquals("two", out.readText())
        assertEquals(listOf("page.jpg"), out.parentFile!!.list()!!.toList())
    }

    @Test fun failedWriteKeepsTheOldFile() {
        val out = File(temp.root, "page.jpg").apply { writeText("old") }
        try {
            PageRenderer.writeAtomically(out) { it.writeText("half"); throw IOException("disk full") }
        } catch (_: IOException) {
        }
        assertEquals("old", out.readText())
        assertEquals(listOf("page.jpg"), temp.root.list()!!.toList())
    }
}
