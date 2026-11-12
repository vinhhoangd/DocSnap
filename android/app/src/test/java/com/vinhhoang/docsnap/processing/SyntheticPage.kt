package com.vinhhoang.docsnap.processing

import java.util.Random
import kotlin.math.exp
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.roundToInt

/**
 * A photographed page made from scratch: off-white paper, rows of dark "words" (some in blue
 * ink), a lighting gradient, a soft shadow in the bottom-right corner, and camera blur.
 * Everything is built in linear light and encoded to sRGB, like a real photo.
 */
class SyntheticPage(
    val width: Int = 600,
    val height: Int = 800,
    lightingGradient: Boolean = true,
    shadow: Boolean = true,
    blurRadius: Int = 1,
    seed: Long = 7,
) {
    val pixels: IntArray
    /** Centre rows of the strokes: what must stay ink. */
    val inkCore = BooleanArray(width * height)
    /** Like [inkCore], but only the blue-ink strokes. */
    val blueCore = BooleanArray(width * height)
    /** Paper at least [PAPER_CLEARANCE] px from any stroke. */
    val paper = BooleanArray(width * height)

    init {
        val n = width * height
        val r = FloatArray(n) { PAPER }
        val g = FloatArray(n) { PAPER }
        val b = FloatArray(n) { PAPER * 0.97f } // slightly warm paper
        val stroke = BooleanArray(n)
        val rnd = Random(seed)
        var row = 0
        var y = 40
        while (y + 3 < height - 40) {
            val blue = row % 3 == 2
            var x = 40
            while (x < width - 40) {
                val len = 20 + rnd.nextInt(40)
                val end = min(x + len, width - 40)
                for (yy in y until y + 3) for (xx in x until end) {
                    val i = yy * width + xx
                    stroke[i] = true
                    if (blue) { r[i] = 0.03f; g[i] = 0.06f; b[i] = 0.35f } else { r[i] = INK; g[i] = INK; b[i] = INK }
                    if (yy == y + 1 && xx > x + 1 && xx < end - 2) {
                        inkCore[i] = true
                        if (blue) blueCore[i] = true
                    }
                }
                // a few "letter" ticks above the bar
                for (xx in x until end step 7) for (yy in max(0, y - 6) until y) {
                    val i = yy * width + xx
                    stroke[i] = true
                    if (blue) { r[i] = 0.03f; g[i] = 0.06f; b[i] = 0.35f } else { r[i] = INK; g[i] = INK; b[i] = INK }
                }
                x = end + 12
            }
            y += 26
            row++
        }
        // Paper mask: no stroke within the clearance (dilate the stroke map).
        val near = BooleanArray(n)
        for (yy in 0 until height) for (xx in 0 until width) if (stroke[yy * width + xx]) {
            for (dy in -PAPER_CLEARANCE..PAPER_CLEARANCE) for (dx in -PAPER_CLEARANCE..PAPER_CLEARANCE) {
                val px = xx + dx
                val py = yy + dy
                if (px in 0 until width && py in 0 until height) near[py * width + px] = true
            }
        }
        for (i in 0 until n) paper[i] = !near[i]

        boxBlur(r, blurRadius); boxBlur(g, blurRadius); boxBlur(b, blurRadius)

        pixels = IntArray(n) { i ->
            val x = i % width
            val yy = i / width
            var light = 1f
            if (lightingGradient) light *= 1f - 0.25f * x / width
            if (shadow) {
                val d = hypot((width - x).toDouble(), (height - yy).toDouble()) / (0.35 * width)
                light *= (1 - 0.5 * exp(-d * d)).toFloat()
            }
            rgb(r[i] * light, g[i] * light, b[i] * light)
        }
    }

    /** Pixels in the bottom-right corner, inside the shadow. */
    fun inShadowCorner(i: Int): Boolean = i % width >= width - 120 && i / width >= height - 120

    private fun boxBlur(c: FloatArray, radius: Int) {
        if (radius <= 0) return
        val tmp = c.copyOf()
        for (y in 0 until height) for (x in 0 until width) {
            var s = 0f
            for (k in -radius..radius) s += tmp[y * width + (x + k).coerceIn(0, width - 1)]
            c[y * width + x] = s / (2 * radius + 1)
        }
        tmp.indices.forEach { tmp[it] = c[it] }
        for (y in 0 until height) for (x in 0 until width) {
            var s = 0f
            for (k in -radius..radius) s += tmp[(y + k).coerceIn(0, height - 1) * width + x]
            c[y * width + x] = s / (2 * radius + 1)
        }
    }

    companion object {
        const val PAPER = 0.82f
        const val INK = 0.02f
        const val PAPER_CLEARANCE = 8

        fun encode(v: Float): Int {
            val l = v.toDouble().coerceIn(0.0, 1.0)
            val s = if (l <= 0.0031308) 12.92 * l else 1.055 * l.pow(1 / 2.4) - 0.055
            return (s * 255).roundToInt().coerceIn(0, 255)
        }

        fun rgb(r: Float, g: Float, b: Float): Int =
            (0xFF shl 24) or (encode(r) shl 16) or (encode(g) shl 8) or encode(b)

        fun red(p: Int) = (p shr 16) and 0xFF
        fun green(p: Int) = (p shr 8) and 0xFF
        fun blue(p: Int) = p and 0xFF
        fun luma(p: Int) = (red(p) * 299 + green(p) * 587 + blue(p) * 114) / 1000
    }
}
