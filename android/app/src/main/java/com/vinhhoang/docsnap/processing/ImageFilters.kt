package com.vinhhoang.docsnap.processing

import com.vinhhoang.docsnap.model.ScanFilter
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.roundToInt

/**
 * Pure-Kotlin page filters on ARGB pixels (no Android types, so they run in JVM unit tests).
 * Port of the iPhone app's ImageProcessor (DocSnap/Services/ImageProcessor.swift): Magic Color,
 * Grayscale, B&W, Lighten, with the same tuned parameters.
 *
 * Core Image works in linear light, so every step here runs in linear light too: pixels are
 * decoded from sRGB with a lookup table, filtered as floats and re-encoded to sRGB. That keeps the
 * iOS numbers (levels 0.06/0.85, threshold 0.32–0.62, contrast pivot 0.5, exposure EV) meaning the
 * same thing on both platforms, instead of retuning them for gamma-encoded values.
 *
 * Memory: besides the output array, a filter allocates one 16-bit plane (2 bytes per pixel) for
 * the sharpening blur, plus a ≤512 px background map and a few row buffers. Nothing is allocated
 * per pixel. Each filter makes two passes over the pixels plus a separable blur of the plane.
 */
object ImageFilters {
    /** Returns a new ARGB array; `pixels` is not modified. */
    fun apply(filter: ScanFilter, pixels: IntArray, width: Int, height: Int): IntArray {
        checkSize(pixels, width, height)
        if (filter == ScanFilter.Original) return pixels.copyOf()
        val out = IntArray(pixels.size)
        render(filter, pixels, out, width, height, sharpen = true)
        return out
    }

    /** Like [apply] but overwrites `pixels` with the result, so a 12 MP page needs no second 48 MB array. */
    fun applyInPlace(filter: ScanFilter, pixels: IntArray, width: Int, height: Int) {
        checkSize(pixels, width, height)
        if (filter == ScanFilter.Original) return
        render(filter, pixels, pixels, width, height, sharpen = true)
    }

    /** Sharpening radius in pixels: text strokes scale with resolution (same rule as iOS). */
    fun sharpenRadius(width: Int, height: Int): Float = (max(width, height) / 1500f).coerceIn(1f, 3.5f)

    private fun checkSize(pixels: IntArray, width: Int, height: Int) {
        require(width >= 0 && height >= 0) { "size must not be negative" }
        require(pixels.size.toLong() == width.toLong() * height.toLong()) { "pixel count must match the size" }
    }

    // MARK: - Pipelines

    /**
     * Applies `filter` reading `src` and writing `dst` (which may be the same array: every pass
     * reads pixel i before writing pixel i, and only the last pass writes).
     * `sharpen = false` skips the sharpening step; tests use it as the "unsharpened" reference.
     */
    internal fun render(filter: ScanFilter, src: IntArray, dst: IntArray, width: Int, height: Int, sharpen: Boolean) {
        val n = width * height
        if (n == 0) return
        when (filter) {
            ScanFilter.Original -> if (dst !== src) src.copyInto(dst)
            ScanFilter.Grayscale -> grayscale(src, dst, width, height, sharpen)
            ScanFilter.Lighten -> lighten(src, dst, width, height, sharpen)
            ScanFilter.MagicColor -> magicColor(src, dst, width, height, sharpen)
            ScanFilter.BlackWhite -> blackWhite(src, dst, width, height, sharpen)
        }
    }

    /** iOS: colorControls(saturation 0, contrast 1.1, brightness 0.02), then a darken-only unsharp mask (radius ×1.2, intensity 0.55). */
    private fun grayscale(src: IntArray, dst: IntArray, w: Int, h: Int, sharpen: Boolean) {
        val n = w * h
        val plane = if (sharpen) ShortArray(n) else null
        if (plane != null) {
            for (i in 0 until n) plane[i] = toPlane(grayBase(src[i]))
            blurPlane(plane, w, h, sharpenRadius(w, h) * 1.2f)
        }
        for (i in 0 until n) {
            val p = src[i]
            val g = grayBase(p)
            val v = if (plane != null) min(g + 0.55f * (g - fromPlane(plane[i])), g) else g
            dst[i] = gray(p, encode(v))
        }
    }

    /** CIColorControls on gray: brightness, then contrast around 0.5. */
    private fun grayBase(p: Int): Float = contrast(luma(p) + 0.02f, 1.1f)

    /** iOS: exposure +0.7 EV, colorControls(saturation 1.05, contrast 1.05), darken-only luminance sharpening 0.45. */
    private fun lighten(src: IntArray, dst: IntArray, w: Int, h: Int, sharpen: Boolean) {
        val n = w * h
        val plane = if (sharpen) ShortArray(n) else null
        if (plane != null) {
            for (i in 0 until n) {
                val p = src[i]
                // Saturation keeps luma, so the lighter image's luma is the controlled luma.
                plane[i] = toPlane(contrast(luma(p) * EXPOSURE_GAIN, LIGHTEN_CONTRAST))
            }
            blurPlane(plane, w, h, sharpenRadius(w, h))
        }
        for (i in 0 until n) {
            val p = src[i]
            val r = lin(p shr 16) * EXPOSURE_GAIN
            val g = lin(p shr 8) * EXPOSURE_GAIN
            val b = lin(p) * EXPOSURE_GAIN
            val l = luma(r, g, b)
            val lr = contrast(l + LIGHTEN_SATURATION * (r - l), LIGHTEN_CONTRAST)
            val lg = contrast(l + LIGHTEN_SATURATION * (g - l), LIGHTEN_CONTRAST)
            val lb = contrast(l + LIGHTEN_SATURATION * (b - l), LIGHTEN_CONTRAST)
            var d = 0f
            if (plane != null) {
                val base = contrast(l, LIGHTEN_CONTRAST)
                d = min(LUMA_SHARPEN_GAIN * 0.45f * (base - fromPlane(plane[i])), 0f) // darken only
            }
            dst[i] = argb(p, encode(lr + d), encode(lg + d), encode(lb + d))
        }
    }

    /**
     * iOS: divide out the lighting (paper → white, ink keeps its colour), luminance sharpening 0.7,
     * levels black 0.06 / white 0.85, then colorControls(saturation 1.25, contrast 1.08).
     */
    private fun magicColor(src: IntArray, dst: IntArray, w: Int, h: Int, sharpen: Boolean) {
        val n = w * h
        val bg = Background.estimate(src, w, h, colour = true)
        val rowR = FloatArray(max(1, bg?.sw ?: 1))
        val rowG = FloatArray(rowR.size)
        val rowB = FloatArray(rowR.size)
        val plane = if (sharpen) ShortArray(n) else null
        if (plane != null) {
            for (y in 0 until h) {
                bg?.row(y, rowR, rowG, rowB)
                val o = y * w
                for (x in 0 until w) {
                    val p = src[o + x]
                    var r = lin(p shr 16); var g = lin(p shr 8); var b = lin(p)
                    if (bg != null) {
                        r /= bg.at(rowR, x); g /= bg.at(rowG, x); b /= bg.at(rowB, x)
                    }
                    plane[o + x] = toPlane(luma(r, g, b))
                }
            }
            blurPlane(plane, w, h, sharpenRadius(w, h))
        }
        val scale = 1f / (MAGIC_WHITE - MAGIC_BLACK)
        for (y in 0 until h) {
            bg?.row(y, rowR, rowG, rowB)
            val o = y * w
            for (x in 0 until w) {
                val i = o + x
                val p = src[i]
                var r = lin(p shr 16); var g = lin(p shr 8); var b = lin(p)
                if (bg != null) {
                    r /= bg.at(rowR, x); g /= bg.at(rowG, x); b /= bg.at(rowB, x)
                }
                if (plane != null) {
                    val d = LUMA_SHARPEN_GAIN * 0.7f * (luma(r, g, b) - fromPlane(plane[i]))
                    r += d; g += d; b += d
                }
                // Levels (clamped, as CIColorClamp does).
                r = ((r - MAGIC_BLACK) * scale).coerceIn(0f, 1f)
                g = ((g - MAGIC_BLACK) * scale).coerceIn(0f, 1f)
                b = ((b - MAGIC_BLACK) * scale).coerceIn(0f, 1f)
                val l = luma(r, g, b)
                dst[i] = argb(
                    p,
                    encode(contrast(l + MAGIC_SATURATION * (r - l), MAGIC_CONTRAST)),
                    encode(contrast(l + MAGIC_SATURATION * (g - l), MAGIC_CONTRAST)),
                    encode(contrast(l + MAGIC_SATURATION * (b - l), MAGIC_CONTRAST)),
                )
            }
        }
    }

    /** iOS: gray, flatten the lighting, unsharp mask (intensity 0.9), then levels 0.32–0.62 (a steep ramp, not a hard threshold). */
    private fun blackWhite(src: IntArray, dst: IntArray, w: Int, h: Int, sharpen: Boolean) {
        val n = w * h
        val bg = Background.estimate(src, w, h, colour = false)
        val row = FloatArray(max(1, bg?.sw ?: 1))
        val plane = if (sharpen) ShortArray(n) else null
        if (plane != null) {
            for (y in 0 until h) {
                bg?.row(y, row)
                val o = y * w
                for (x in 0 until w) {
                    var l = luma(src[o + x])
                    if (bg != null) l /= bg.at(row, x)
                    plane[o + x] = toPlane(l)
                }
            }
            blurPlane(plane, w, h, sharpenRadius(w, h))
        }
        val scale = 1f / (BW_WHITE - BW_BLACK)
        for (y in 0 until h) {
            bg?.row(y, row)
            val o = y * w
            for (x in 0 until w) {
                val i = o + x
                val p = src[i]
                var l = luma(p)
                if (bg != null) l /= bg.at(row, x)
                if (plane != null) l += 0.9f * (l - fromPlane(plane[i]))
                dst[i] = gray(p, encode((l - BW_BLACK) * scale))
            }
        }
    }

    // MARK: - Lighting flattening

    /**
     * The paper's brightness, estimated like iOS `flattenedLighting`: downscale to ≤512 px, a max
     * (dilate) filter removes the text, a Gaussian blur smooths it. Kept small and upsampled
     * bilinearly per row on demand, so it costs a few hundred KB whatever the page size.
     */
    internal class Background private constructor(
        val sw: Int,
        val sh: Int,
        private val channels: Array<FloatArray>,
        private val fullH: Int,
        fullW: Int,
    ) {
        private val x0 = IntArray(fullW)
        private val x1 = IntArray(fullW)
        private val wx = FloatArray(fullW)

        init {
            val sx = sw.toFloat() / fullW
            for (x in 0 until fullW) {
                val f = ((x + 0.5f) * sx - 0.5f).coerceIn(0f, (sw - 1).toFloat())
                val i = floor(f).toInt()
                x0[x] = i
                x1[x] = min(i + 1, sw - 1)
                wx[x] = f - i
            }
        }

        /** Fills `out` (one array per channel) with row `y` of the background, still at the small width. */
        fun row(y: Int, vararg out: FloatArray) {
            val f = ((y + 0.5f) * sh / fullH - 0.5f).coerceIn(0f, (sh - 1).toFloat())
            val y0 = floor(f).toInt()
            val y1 = min(y0 + 1, sh - 1)
            val wy = f - y0
            for (c in out.indices) {
                val s = channels[c]
                val o = out[c]
                val a = y0 * sw
                val b = y1 * sw
                for (j in 0 until sw) o[j] = s[a + j] + (s[b + j] - s[a + j]) * wy
            }
        }

        /** The background at full-size column `x`, from a row filled by [row]. Never below a small floor (no division by 0). */
        fun at(row: FloatArray, x: Int): Float {
            val a = row[x0[x]]
            return max(a + (row[x1[x]] - a) * wx[x], MIN_BACKGROUND)
        }

        companion object {
            /** Null when the page is too small to flatten (iOS skips it under 16 px too). */
            fun estimate(src: IntArray, w: Int, h: Int, colour: Boolean): Background? {
                val longest = max(w, h)
                if (longest < 16) return null
                val scale = min(1f, 512f / longest)
                val sw = max(1, (w * scale).roundToInt())
                val sh = max(1, (h * scale).roundToInt())
                val count = IntArray(sw * sh)
                val nc = if (colour) 3 else 1
                val ch = Array(nc) { FloatArray(sw * sh) }
                // Area-average downscale, in linear light.
                val bx = IntArray(w) { min(sw - 1, (it.toLong() * sw / w).toInt()) }
                for (y in 0 until h) {
                    val by = min(sh - 1, (y.toLong() * sh / h).toInt()) * sw
                    val o = y * w
                    for (x in 0 until w) {
                        val p = src[o + x]
                        val k = by + bx[x]
                        count[k]++
                        if (colour) {
                            ch[0][k] += lin(p shr 16); ch[1][k] += lin(p shr 8); ch[2][k] += lin(p)
                        } else {
                            ch[0][k] += luma(p)
                        }
                    }
                }
                val smallLongest = longest * scale
                val dilate = max(2f, smallLongest / 60f).roundToInt()
                val sigma = max(2f, smallLongest / 40f)
                for (c in ch) {
                    for (k in c.indices) c[k] /= max(1, count[k])
                    maxFilter(c, sw, sh, dilate)
                    blurFloat(c, sw, sh, sigma)
                }
                return Background(sw, sh, ch, h, w)
            }
        }
    }

    /** Separable square max filter (morphological dilation) with radius `r`, edges clamped. */
    internal fun maxFilter(data: FloatArray, w: Int, h: Int, r: Int) {
        val line = FloatArray(max(w, h))
        for (y in 0 until h) {
            val o = y * w
            for (x in 0 until w) line[x] = data[o + x]
            for (x in 0 until w) {
                var m = line[x]
                for (k in max(0, x - r)..min(w - 1, x + r)) if (line[k] > m) m = line[k]
                data[o + x] = m
            }
        }
        for (x in 0 until w) {
            for (y in 0 until h) line[y] = data[y * w + x]
            for (y in 0 until h) {
                var m = line[y]
                for (k in max(0, y - r)..min(h - 1, y + r)) if (line[k] > m) m = line[k]
                data[y * w + x] = m
            }
        }
    }

    // MARK: - Gaussian blur (three fractional box passes per direction)

    /** Radius of one fractional box so that three passes have variance sigma². */
    internal fun boxRadius(sigma: Float): Float {
        val target = sigma.toDouble() * sigma / BOX_PASSES
        var lo = 0.0
        var hi = 3.0 * sigma + 2
        repeat(40) {
            val mid = (lo + hi) / 2
            if (boxVariance(mid) < target) lo = mid else hi = mid
        }
        return ((lo + hi) / 2).toFloat()
    }

    /** Variance of a box with weight 1 on |k| ≤ ri and `f` on |k| = ri + 1, where r = ri + f. */
    internal fun boxVariance(r: Double): Double {
        val ri = floor(r).toInt()
        val f = r - ri
        val sumK2 = ri.toDouble() * (ri + 1) * (2 * ri + 1) / 6.0
        return (2 * sumK2 + 2 * f * (ri + 1).toDouble() * (ri + 1)) / (2 * ri + 1 + 2 * f)
    }

    /** One box pass over data[off until off+n], in place, edges clamped. `pad` holds n + 2(ri+1) floats. */
    private fun boxPass(data: FloatArray, off: Int, n: Int, ri: Int, f: Float, pad: FloatArray) {
        val e = ri + 1
        val first = data[off]
        val last = data[off + n - 1]
        for (k in 0 until e) {
            pad[k] = first
            pad[e + n + k] = last
        }
        System.arraycopy(data, off, pad, e, n)
        val norm = 1.0 / (2 * ri + 1 + 2 * f)
        var s = 0.0
        for (k in e - ri..e + ri) s += pad[k]
        for (i in 0 until n) {
            val c = e + i
            data[off + i] = ((s + f * (pad[c - ri - 1] + pad[c + ri + 1])) * norm).toFloat()
            s += pad[c + ri + 1] - pad[c - ri]
        }
    }

    private fun blurLine(data: FloatArray, off: Int, n: Int, ri: Int, f: Float, pad: FloatArray) {
        repeat(BOX_PASSES) { boxPass(data, off, n, ri, f, pad) }
    }

    /** Gaussian-like blur of a small float image (the background map). */
    internal fun blurFloat(data: FloatArray, w: Int, h: Int, sigma: Float) {
        if (sigma <= 0f) return
        val r = boxRadius(sigma)
        val ri = floor(r).toInt()
        val f = r - ri
        val pad = FloatArray(max(w, h) + 2 * (ri + 1))
        for (y in 0 until h) blurLine(data, y * w, w, ri, f, pad)
        val col = FloatArray(h)
        for (x in 0 until w) {
            for (y in 0 until h) col[y] = data[y * w + x]
            blurLine(col, 0, h, ri, f, pad)
            for (y in 0 until h) data[y * w + x] = col[y]
        }
    }

    /**
     * Gaussian-like blur of a full-size 16-bit plane, in place. Rows are blurred one at a time;
     * columns in blocks of [COLUMN_BLOCK] gathered into a contiguous buffer, which keeps memory
     * access cache-friendly without a second full-size plane.
     */
    internal fun blurPlane(plane: ShortArray, w: Int, h: Int, sigma: Float) {
        if (sigma <= 0f || w == 0 || h == 0) return
        val r = boxRadius(sigma)
        val ri = floor(r).toInt()
        val f = r - ri
        val pad = FloatArray(max(w, h) + 2 * (ri + 1))
        val line = FloatArray(w)
        for (y in 0 until h) {
            val o = y * w
            for (x in 0 until w) line[x] = fromPlane(plane[o + x])
            blurLine(line, 0, w, ri, f, pad)
            for (x in 0 until w) plane[o + x] = toPlane(line[x])
        }
        val block = FloatArray(COLUMN_BLOCK * h)
        var x0 = 0
        while (x0 < w) {
            val bw = min(COLUMN_BLOCK, w - x0)
            for (y in 0 until h) {
                val o = y * w + x0
                for (c in 0 until bw) block[c * h + y] = fromPlane(plane[o + c])
            }
            for (c in 0 until bw) blurLine(block, c * h, h, ri, f, pad)
            for (y in 0 until h) {
                val o = y * w + x0
                for (c in 0 until bw) plane[o + c] = toPlane(block[c * h + y])
            }
            x0 += bw
        }
    }

    // MARK: - Colour helpers (linear light)

    private const val BOX_PASSES = 3
    private const val COLUMN_BLOCK = 32
    private const val MIN_BACKGROUND = 1e-3f

    /** 2^0.7: iOS CIExposureAdjust ev 0.7, a multiply in linear light. */
    private val EXPOSURE_GAIN = 2f.pow(0.7f)
    private const val LIGHTEN_SATURATION = 1.05f
    private const val LIGHTEN_CONTRAST = 1.05f
    private const val MAGIC_BLACK = 0.06f
    private const val MAGIC_WHITE = 0.85f
    private const val MAGIC_SATURATION = 1.25f
    private const val MAGIC_CONTRAST = 1.08f
    private const val BW_BLACK = 0.32f
    private const val BW_WHITE = 0.62f

    /**
     * CISharpenLuminance's exact kernel is undocumented; it is modelled as an unsharp mask on luma
     * (Gaussian sigma = radius) with amount = sharpness × this gain.
     */
    private const val LUMA_SHARPEN_GAIN = 1f

    // Rec. 709 luma in linear light, the weights CIColorControls uses.
    private const val KR = 0.2125f
    private const val KG = 0.7154f
    private const val KB = 0.0721f

    private val TO_LINEAR = FloatArray(256) { i ->
        val c = i / 255.0
        (if (c <= 0.04045) c / 12.92 else ((c + 0.055) / 1.055).pow(2.4)).toFloat()
    }

    private const val SRGB_LUT_SIZE = 16384
    private val TO_SRGB = IntArray(SRGB_LUT_SIZE + 1) { i ->
        val l = i.toDouble() / SRGB_LUT_SIZE
        val s = if (l <= 0.0031308) 12.92 * l else 1.055 * l.pow(1 / 2.4) - 0.055
        (s * 255 + 0.5).toInt().coerceIn(0, 255)
    }

    private const val PLANE_SCALE = 32768f
    private const val PLANE_MAX = 65535f / PLANE_SCALE

    /** Linear value of an 8-bit sRGB channel; only the low 8 bits of `c` are used. */
    private fun lin(c: Int): Float = TO_LINEAR[c and 0xFF]

    private fun luma(r: Float, g: Float, b: Float): Float = KR * r + KG * g + KB * b
    private fun luma(p: Int): Float = luma(lin(p shr 16), lin(p shr 8), lin(p))

    private fun contrast(v: Float, amount: Float): Float = (v - 0.5f) * amount + 0.5f

    /** Linear [0, 1] → 8-bit sRGB, clamped (also maps NaN to 0). */
    private fun encode(v: Float): Int {
        if (!(v > 0f)) return 0
        if (v >= 1f) return 255
        return TO_SRGB[(v * SRGB_LUT_SIZE + 0.5f).toInt()]
    }

    /** Stores a linear value in [0, 2) as unsigned 16-bit (light above paper white survives for Lighten/Magic Color). */
    private fun toPlane(v: Float): Short = (v.coerceIn(0f, PLANE_MAX) * PLANE_SCALE + 0.5f).toInt().toShort()
    private fun fromPlane(s: Short): Float = (s.toInt() and 0xFFFF) / PLANE_SCALE

    private fun argb(src: Int, r: Int, g: Int, b: Int): Int = (src and 0xFF000000.toInt()) or (r shl 16) or (g shl 8) or b
    private fun gray(src: Int, v: Int): Int = argb(src, v, v, v)

    /** Exposed for tests: 8-bit sRGB → linear → 8-bit sRGB must be the identity. */
    internal fun roundTrip(c: Int): Int = encode(lin(c))
}
