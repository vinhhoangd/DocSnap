package com.vinhhoang.docsnap.processing

import com.vinhhoang.docsnap.model.ScanFilter
import com.vinhhoang.docsnap.processing.SyntheticPage.Companion.blue
import com.vinhhoang.docsnap.processing.SyntheticPage.Companion.green
import com.vinhhoang.docsnap.processing.SyntheticPage.Companion.luma
import com.vinhhoang.docsnap.processing.SyntheticPage.Companion.red
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import kotlin.math.abs

class ImageFiltersTest {
    private val filtered = ScanFilter.entries.filter { it != ScanFilter.Original }

    companion object {
        // Built once: generating and filtering a page takes a moment.
        private val page = SyntheticPage()
        private val outputs: Map<ScanFilter, IntArray> =
            ScanFilter.entries.associateWith { ImageFilters.apply(it, page.pixels, page.width, page.height) }

        private fun fraction(mask: BooleanArray, test: (Int) -> Boolean): Double {
            var total = 0
            var hits = 0
            for (i in mask.indices) if (mask[i]) {
                total++
                if (test(i)) hits++
            }
            assertTrue("mask is empty", total > 0)
            return hits.toDouble() / total
        }

        private fun and(a: BooleanArray, f: (Int) -> Boolean) = BooleanArray(a.size) { a[it] && f(it) }
    }

    // MARK: - The synthetic page itself (so the other tests mean something)

    @Test fun syntheticPageHasADarkShadowAndGreyPaper() {
        val corner = and(page.paper) { page.inShadowCorner(it) }
        assertTrue("shadowed paper should start dark", fraction(corner) { luma(page.pixels[it]) < 190 } > 0.9)
        assertTrue("paper should not start white", fraction(page.paper) { luma(page.pixels[it]) >= 245 } < 0.01)
    }

    // MARK: - Magic Color

    @Test fun magicColorTurnsPaperWhite() {
        val out = outputs.getValue(ScanFilter.MagicColor)
        val white = fraction(page.paper) { val p = out[it]; red(p) >= 245 && green(p) >= 245 && blue(p) >= 245 }
        assertTrue("paper white: $white", white > 0.98)
    }

    @Test fun magicColorWhitensTheShadowedCorner() {
        val out = outputs.getValue(ScanFilter.MagicColor)
        val corner = and(page.paper) { page.inShadowCorner(it) }
        val white = fraction(corner) { luma(out[it]) >= 240 }
        assertTrue("shadowed paper white: $white", white > 0.97)
    }

    @Test fun magicColorKeepsInkDark() {
        val out = outputs.getValue(ScanFilter.MagicColor)
        val black = and(page.inkCore) { !page.blueCore[it] }
        val dark = fraction(black) { luma(out[it]) < 70 }
        assertTrue("black ink dark: $dark", dark > 0.95)
    }

    @Test fun magicColorKeepsInkDarkInTheShadow() {
        val out = outputs.getValue(ScanFilter.MagicColor)
        val shadowInk = and(page.inkCore) { !page.blueCore[it] && page.inShadowCorner(it) }
        assertTrue("shadowed ink dark", fraction(shadowInk) { luma(out[it]) < 80 } > 0.9)
    }

    @Test fun magicColorKeepsBlueInkBlue() {
        val out = outputs.getValue(ScanFilter.MagicColor)
        val blueish = fraction(page.blueCore) { val p = out[it]; blue(p) > red(p) + 60 && blue(p) > green(p) + 40 }
        assertTrue("blue ink stays blue: $blueish", blueish > 0.9)
    }

    // MARK: - Grayscale

    @Test fun grayscaleIsGray() {
        val out = outputs.getValue(ScanFilter.Grayscale)
        for (p in out) {
            if (red(p) != green(p) || green(p) != blue(p)) fail("not gray: ${Integer.toHexString(p)}")
        }
    }

    @Test fun grayscaleKeepsInkDarkAndPaperLight() {
        val out = outputs.getValue(ScanFilter.Grayscale)
        assertTrue(fraction(page.inkCore) { luma(out[it]) < 90 } > 0.95)
        val unshadowed = and(page.paper) { !page.inShadowCorner(it) }
        assertTrue(fraction(unshadowed) { luma(out[it]) > 180 } > 0.95)
    }

    @Test fun grayscaleSharpeningOnlyDarkens() = assertDarkenOnly(ScanFilter.Grayscale)

    // MARK: - B&W

    @Test fun blackWhiteIsMostlyBlackOrWhite() {
        val out = outputs.getValue(ScanFilter.BlackWhite)
        var middle = 0
        for (p in out) {
            assertEquals(red(p), green(p)); assertEquals(green(p), blue(p))
            if (red(p) in 31..224) middle++
        }
        val share = middle.toDouble() / out.size
        assertTrue("mid-tones: $share", share < 0.05)
    }

    @Test fun blackWhiteTurnsPaperWhiteIncludingTheShadow() {
        val out = outputs.getValue(ScanFilter.BlackWhite)
        assertTrue(fraction(page.paper) { red(out[it]) >= 250 } > 0.98)
        val corner = and(page.paper) { page.inShadowCorner(it) }
        assertTrue(fraction(corner) { red(out[it]) >= 250 } > 0.97)
    }

    @Test fun blackWhiteKeepsInkBlack() {
        val out = outputs.getValue(ScanFilter.BlackWhite)
        val black = and(page.inkCore) { !page.blueCore[it] }
        assertTrue(fraction(black) { red(out[it]) <= 20 } > 0.95)
        assertTrue("blue ink should read as dark", fraction(page.blueCore) { red(out[it]) <= 60 } > 0.9)
    }

    // MARK: - Lighten

    @Test fun lightenBrightensPaperAndKeepsInk() {
        val out = outputs.getValue(ScanFilter.Lighten)
        var brighter = 0
        var total = 0
        for (i in out.indices) if (page.paper[i]) {
            total++
            if (luma(out[i]) > luma(page.pixels[i])) brighter++
        }
        assertTrue(brighter.toDouble() / total > 0.99)
        val black = and(page.inkCore) { !page.blueCore[it] }
        assertTrue(fraction(black) { luma(out[it]) < 90 } > 0.95)
    }

    @Test fun lightenSharpeningOnlyDarkens() = assertDarkenOnly(ScanFilter.Lighten)

    private fun assertDarkenOnly(filter: ScanFilter) {
        val sharp = outputs.getValue(filter)
        val soft = IntArray(sharp.size)
        ImageFilters.render(filter, page.pixels, soft, page.width, page.height, sharpen = false)
        var darker = 0
        for (i in sharp.indices) {
            val s = sharp[i]
            val u = soft[i]
            if (red(s) > red(u) || green(s) > green(u) || blue(s) > blue(u)) {
                fail("$filter brightened pixel $i: ${Integer.toHexString(u)} → ${Integer.toHexString(s)}")
            }
            if (s != u) darker++
        }
        assertTrue("$filter sharpening should change some pixels", darker > 0)
    }

    // MARK: - Sharpening

    /** A blurred vertical stroke of `ink` (linear) on paper: ink between x=196 and 201, 5 px ramps. */
    private fun stroke(ink: Float, w: Int = 400, h: Int = 60) = IntArray(w * h) { i ->
        val x = i % w
        val t = when {
            x < 191 || x > 206 -> 0f
            x < 196 -> (x - 191) / 5f
            x > 201 -> (206 - x) / 5f
            else -> 1f
        }
        val v = 0.85f * (1 - t) + ink * t
        SyntheticPage.rgb(v, v, v)
    }

    private fun unsharpened(filter: ScanFilter, px: IntArray, w: Int, h: Int) =
        IntArray(px.size).also { ImageFilters.render(filter, px, it, w, h, sharpen = false) }

    /**
     * Sharpening must steepen a soft edge. Pencil-gray ink, so no filter clips the stroke to
     * black: with clipping the steepest sRGB step sits at the clip point, which measures the
     * levels, not the sharpening.
     */
    @Test fun sharpeningRaisesTheEdgeGradient() {
        val w = 400
        val h = 60
        val px = stroke(0.3f)
        for (filter in filtered) {
            val gSharp = maxGradient(ImageFilters.apply(filter, px, w, h), w, h)
            val gSoft = maxGradient(unsharpened(filter, px, w, h), w, h)
            assertTrue("$filter: edge gradient $gSoft → $gSharp", gSharp > gSoft)
        }
    }

    /** With dark ink, sharpening must not widen the paper-to-ink transition. */
    @Test fun sharpeningKeepsDarkStrokeEdgesNarrow() {
        val w = 400
        val h = 60
        val px = stroke(0.02f)
        for (filter in filtered) {
            val sharp = transitionWidth(ImageFilters.apply(filter, px, w, h), w, h)
            val soft = transitionWidth(unsharpened(filter, px, w, h), w, h)
            assertTrue("$filter: transition $soft → $sharp px", sharp <= soft)
        }
    }

    /** Pixels on the middle row that are neither paper nor ink (between 10 % and 90 % of the row's range). */
    private fun transitionWidth(px: IntArray, w: Int, h: Int): Int {
        val row = IntArray(w) { luma(px[(h / 2) * w + it]) }
        val lo = row.min()
        val hi = row.max()
        val a = lo + (hi - lo) / 10
        val b = hi - (hi - lo) / 10
        return row.count { it in (a + 1) until b }
    }

    private fun maxGradient(px: IntArray, w: Int, h: Int): Int {
        var m = 0
        val y = h / 2
        for (x in 1 until w) m = maxOf(m, abs(luma(px[y * w + x]) - luma(px[y * w + x - 1])))
        return m
    }

    @Test fun sharpenRadiusScalesWithSizeLikeIos() {
        assertEquals(1f, ImageFilters.sharpenRadius(800, 600), 0f)
        assertEquals(2f, ImageFilters.sharpenRadius(3000, 2000), 1e-6f)
        assertEquals(4096 / 1500f, ImageFilters.sharpenRadius(3072, 4096), 1e-6f)
        assertEquals(3.5f, ImageFilters.sharpenRadius(9000, 100), 0f)
    }

    // MARK: - Original, purity, determinism

    @Test fun originalEqualsTheInputButIsACopy() {
        val out = ImageFilters.apply(ScanFilter.Original, page.pixels, page.width, page.height)
        assertArrayEquals(page.pixels, out)
        assertNotSame(page.pixels, out)
    }

    @Test fun inputIsNotModified() {
        val input = page.pixels.copyOf()
        for (filter in ScanFilter.entries) {
            ImageFilters.apply(filter, input, page.width, page.height)
            assertArrayEquals("$filter changed its input", page.pixels, input)
        }
    }

    @Test fun deterministic() {
        for (filter in filtered) {
            assertArrayEquals("$filter", outputs.getValue(filter), ImageFilters.apply(filter, page.pixels, page.width, page.height))
        }
    }

    @Test fun applyInPlaceMatchesApply() {
        for (filter in ScanFilter.entries) {
            val buffer = page.pixels.copyOf()
            ImageFilters.applyInPlace(filter, buffer, page.width, page.height)
            assertArrayEquals("$filter", outputs.getValue(filter), buffer)
        }
    }

    @Test fun alphaIsKept() {
        val px = IntArray(40 * 30) { (0x80 shl 24) or 0x00C0B0A0 }
        for (filter in ScanFilter.entries) {
            for (p in ImageFilters.apply(filter, px, 40, 30)) assertEquals(0x80, p ushr 24)
        }
    }

    // MARK: - Sizes

    @Test fun tinyAndOddSizesWork() {
        val sizes = listOf(1 to 1, 1 to 2, 2 to 1, 1 to 57, 57 to 1, 3 to 3, 15 to 16, 16 to 15, 17 to 31, 333 to 101, 101 to 333)
        for ((w, h) in sizes) {
            val px = IntArray(w * h) { i -> if (i % 3 == 0) 0xFF202020.toInt() else 0xFFD0D0D0.toInt() }
            for (filter in ScanFilter.entries) {
                val out = ImageFilters.apply(filter, px, w, h)
                assertEquals("$filter ${w}x$h", w * h, out.size)
                for (p in out) assertEquals(0xFF, p ushr 24)
            }
        }
    }

    @Test fun emptyImageGivesEmptyResult() {
        for (filter in ScanFilter.entries) {
            assertEquals(0, ImageFilters.apply(filter, IntArray(0), 0, 0).size)
            assertEquals(0, ImageFilters.apply(filter, IntArray(0), 0, 7).size)
        }
    }

    @Test fun largeFlatPageStaysFlat() {
        val w = 2001
        val h = 1499
        val px = IntArray(w * h) { SyntheticPage.rgb(0.6f, 0.6f, 0.58f) }
        for (filter in ScanFilter.entries) {
            val out = ImageFilters.apply(filter, px, w, h)
            val first = out[0]
            for (i in out.indices) if (out[i] != first) fail("$filter not flat at $i: ${Integer.toHexString(out[i])} vs ${Integer.toHexString(first)}")
            if (filter == ScanFilter.MagicColor || filter == ScanFilter.BlackWhite) {
                assertTrue("$filter: flat paper → white, got ${Integer.toHexString(first)}", luma(first) >= 250)
            }
        }
    }

    @Test fun sizeMismatchThrows() {
        for (filter in ScanFilter.entries) {
            expectIllegalArgument { ImageFilters.apply(filter, IntArray(10), 3, 3) }
            expectIllegalArgument { ImageFilters.apply(filter, IntArray(9), 3, 4) }
            expectIllegalArgument { ImageFilters.apply(filter, IntArray(0), -1, 0) }
            expectIllegalArgument { ImageFilters.applyInPlace(filter, IntArray(5), 2, 2) }
        }
    }

    @Test fun overflowingSizeThrowsInsteadOfWrapping() {
        expectIllegalArgument { ImageFilters.apply(ScanFilter.MagicColor, IntArray(0), 65536, 65536) }
    }

    private fun expectIllegalArgument(block: () -> Unit) {
        try {
            block()
            fail("expected IllegalArgumentException")
        } catch (_: IllegalArgumentException) {
        }
    }

    // MARK: - Building blocks

    @Test fun srgbRoundTripIsLossless() {
        for (c in 0..255) assertEquals(c, ImageFilters.roundTrip(c))
    }

    @Test fun threeBoxPassesMatchTheGaussianVariance() {
        for (sigma in listOf(0.5f, 1f, 1.2f, 2f, 3.5f, 4.2f, 12.8f)) {
            val r = ImageFilters.boxRadius(sigma)
            assertEquals("sigma $sigma", sigma.toDouble() * sigma, 3 * ImageFilters.boxVariance(r.toDouble()), 1e-3 * sigma * sigma)
        }
    }

    @Test fun blurSpreadsAnImpulseLikeAGaussian() {
        val n = 201
        val sigma = 4f
        val data = FloatArray(n * n).also { it[100 * n + 100] = 1f }
        ImageFilters.blurFloat(data, n, n, sigma)
        assertEquals(1.0, data.sum().toDouble(), 1e-4)
        var varX = 0.0
        for (y in 0 until n) for (x in 0 until n) varX += data[y * n + x] * (x - 100.0) * (x - 100.0)
        assertEquals(sigma * sigma.toDouble(), varX, 0.05 * sigma * sigma)
        // symmetric
        assertEquals(data[100 * n + 95], data[100 * n + 105], 1e-6f)
        assertEquals(data[95 * n + 100], data[105 * n + 100], 1e-6f)
    }

    @Test fun blurKeepsAConstantImageConstant() {
        val data = FloatArray(37 * 23) { 0.42f }
        ImageFilters.blurFloat(data, 37, 23, 3f)
        for (v in data) assertEquals(0.42f, v, 1e-5f)
    }

    @Test fun maxFilterGrowsABrightPixelIntoASquare() {
        val w = 21
        val data = FloatArray(w * w).also { it[10 * w + 10] = 1f }
        ImageFilters.maxFilter(data, w, w, 3)
        for (y in 0 until w) for (x in 0 until w) {
            val inside = x in 7..13 && y in 7..13
            assertEquals("($x,$y)", if (inside) 1f else 0f, data[y * w + x], 0f)
        }
    }
}
