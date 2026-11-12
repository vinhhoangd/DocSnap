package com.vinhhoang.docsnap.processing

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ColorSpace
import android.graphics.Matrix
import androidx.exifinterface.media.ExifInterface
import com.vinhhoang.docsnap.model.ScanFilter
import com.vinhhoang.docsnap.model.ScanPage
import java.io.File
import java.io.IOException

/**
 * Turns a page's original image into the processed one: rotation, then `page.filter` (see ImageFilters).
 * Must cap memory on 12+ MP images and write a high-quality JPEG (quality ≈ 92) to `output`.
 *
 * Expected peak memory for a 4096 × 3072 page (12.6 MP, the MAX_DIMENSION cap):
 *  - Java heap: the ARGB IntArray (50 MB, filtered in place) + the filter's 16-bit blur plane
 *    (25 MB) + under 3 MB of row buffers and the 512 px background map ≈ 78 MB.
 *  - Native heap (bitmap pixels live there since Android 8): the decoded bitmap (50 MB), plus a
 *    second 50 MB for a moment while rotating/scaling. The decoded bitmap is reused for the output
 *    when it is mutable, so the JPEG encode needs no third copy.
 * A larger source (for example a 50 MP photo) is decoded with inSampleSize first, so it never
 * costs more than about 4× the capped size natively, and the Java side stays at the figures above.
 * If memory still runs out, the page is retried once at half the size.
 */
object PageRenderer {
    /** Longest side kept for originals and processed pages. */
    const val MAX_DIMENSION = 4096
    const val JPEG_QUALITY = 92

    fun render(original: File, page: ScanPage, output: File) {
        try {
            renderAt(original, page, output, MAX_DIMENSION)
        } catch (e: OutOfMemoryError) {
            System.gc()
            renderAt(original, page, output, MAX_DIMENSION / 2)
        }
    }

    private fun renderAt(original: File, page: ScanPage, output: File, maxDimension: Int) {
        val turns = ((page.rotation % 4) + 4) % 4
        val (srcW, srcH) = imageSize(original)
        val orientation = exifOrientation(original)
        val sample = sampleSize(srcW, srcH, maxDimension)
        // Untouched sRGB JPEG: keep the bytes (no generation loss, and much faster). A wide-gamut
        // (e.g. Display P3) photo is re-encoded to sRGB, which PDFs and other apps assume.
        if (page.filter == ScanFilter.Original && turns == 0 && sample == 1 && max(srcW, srcH) <= maxDimension &&
            isUpright(orientation) && isJpeg(original) && isSrgb(original)
        ) {
            writeAtomically(output) { temp -> original.copyTo(temp, overwrite = true) }
            return
        }

        var bitmap = decodeUpright(original, maxDimension, turns, orientation)
        try {
            val w = bitmap.width
            val h = bitmap.height
            if (page.filter != ScanFilter.Original) {
                val pixels = IntArray(w * h)
                bitmap.getPixels(pixels, 0, w, 0, 0, w, h)
                ImageFilters.applyInPlace(page.filter, pixels, w, h)
                if (!bitmap.isMutable) {
                    bitmap.recycle()
                    bitmap = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
                }
                bitmap.setPixels(pixels, 0, w, 0, 0, w, h)
            }
            writeAtomically(output) { temp ->
                temp.outputStream().buffered(1 shl 16).use { out ->
                    if (!bitmap.compress(Bitmap.CompressFormat.JPEG, JPEG_QUALITY, out)) throw IOException("JPEG encode failed")
                }
            }
        } finally {
            bitmap.recycle()
        }
    }

    /**
     * Decodes `file` upright (EXIF orientation applied), turned clockwise by `quarterTurns`, with
     * its longest side at most `maxDimension`. The caller owns (and recycles) the result.
     */
    internal fun decodeUpright(file: File, maxDimension: Int, quarterTurns: Int = 0, orientation: Int = exifOrientation(file)): Bitmap {
        val (srcW, srcH) = imageSize(file)
        val options = BitmapFactory.Options().apply {
            inSampleSize = sampleSize(srcW, srcH, maxDimension)
            inPreferredConfig = Bitmap.Config.ARGB_8888
            // Wide-gamut photos are converted, so filters, JPEGs and PDFs are all plain sRGB.
            inPreferredColorSpace = SRGB
            inMutable = true
        }
        val decoded = BitmapFactory.decodeFile(file.path, options) ?: throw IOException("Can't decode ${file.name}")
        val (dstW, dstH) = fittedSize(decoded.width, decoded.height, maxDimension)
        val matrix = Matrix()
        // Scale with separate x/y factors so the result is exactly dstW × dstH (no partial edge row).
        if (dstW != decoded.width || dstH != decoded.height) {
            matrix.setScale(dstW.toFloat() / decoded.width, dstH.toFloat() / decoded.height)
        }
        matrix.postConcat(orientationMatrix(orientation))
        val turns = ((quarterTurns % 4) + 4) % 4
        if (turns != 0) matrix.postRotate(90f * turns)
        if (matrix.isIdentity) return decoded
        val transformed = try {
            Bitmap.createBitmap(decoded, 0, 0, decoded.width, decoded.height, matrix, true)
        } catch (e: OutOfMemoryError) {
            decoded.recycle()
            throw e
        }
        if (transformed !== decoded) decoded.recycle()
        return transformed
    }

    internal fun imageSize(file: File): Pair<Int, Int> {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.path, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) throw IOException("Can't read image ${file.name}")
        return bounds.outWidth to bounds.outHeight
    }

    internal val SRGB: ColorSpace by lazy { ColorSpace.get(ColorSpace.Named.SRGB) }

    /** True if the image is sRGB, or doesn't say (then sRGB is what every reader assumes). */
    internal fun isSrgb(file: File): Boolean {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.path, bounds)
        val space = bounds.outColorSpace ?: return true
        return space == SRGB
    }

    internal fun exifOrientation(file: File): Int = try {
        ExifInterface(file).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)
    } catch (e: IOException) {
        ExifInterface.ORIENTATION_NORMAL
    }

    internal fun isUpright(orientation: Int) =
        orientation == ExifInterface.ORIENTATION_NORMAL || orientation == ExifInterface.ORIENTATION_UNDEFINED

    /** The transform that turns an image stored with EXIF `orientation` upright (all eight cases). */
    internal fun orientationMatrix(orientation: Int) = Matrix().apply {
        when (orientation) {
            ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> setScale(-1f, 1f)
            ExifInterface.ORIENTATION_ROTATE_180 -> setRotate(180f)
            ExifInterface.ORIENTATION_FLIP_VERTICAL -> { setRotate(180f); postScale(-1f, 1f) }
            ExifInterface.ORIENTATION_TRANSPOSE -> { setRotate(90f); postScale(-1f, 1f) }
            ExifInterface.ORIENTATION_ROTATE_90 -> setRotate(90f)
            ExifInterface.ORIENTATION_TRANSVERSE -> { setRotate(-90f); postScale(-1f, 1f) }
            ExifInterface.ORIENTATION_ROTATE_270 -> setRotate(-90f)
        }
    }

    // MARK: - Pure helpers (JVM-tested)

    /**
     * Largest power-of-two inSampleSize that still leaves the longest side ≥ 3/4 of
     * `maxDimension`. A 50 MP Samsung photo (8160 px) decodes at 4080 px instead of in full
     * (200 MB of native memory); the price is at most a quarter of the cap in rare in-between sizes.
     */
    internal fun sampleSize(width: Int, height: Int, maxDimension: Int): Int {
        val longest = max(width, height).toLong()
        val floor = maxDimension.toLong() * 3 / 4
        var sample = 1
        while (longest / (sample * 2) >= floor && sample < (1 shl 20)) sample *= 2
        return sample
    }

    /** Size with the longest side at most `maxDimension`, aspect kept, each side ≥ 1. */
    internal fun fittedSize(width: Int, height: Int, maxDimension: Int): Pair<Int, Int> {
        val longest = max(width, height)
        if (longest <= maxDimension) return width to height
        val scale = maxDimension.toDouble() / longest
        return Math.max(1, Math.round(width * scale).toInt()) to Math.max(1, Math.round(height * scale).toInt())
    }

    /** True if the file starts with the JPEG SOI marker. */
    internal fun isJpeg(file: File): Boolean = try {
        file.inputStream().use { it.read() == 0xFF && it.read() == 0xD8 }
    } catch (e: IOException) {
        false
    }

    /** Writes through a temp file next to `output`, then renames, so readers never see half a file. */
    internal fun writeAtomically(output: File, write: (temp: File) -> Unit) {
        output.parentFile?.mkdirs()
        val temp = File(output.parentFile, ".${output.name}.tmp")
        try {
            write(temp)
            if (!temp.renameTo(output)) {
                output.delete()
                if (!temp.renameTo(output)) throw IOException("Couldn't save ${output.name}")
            }
        } finally {
            temp.delete()
        }
    }

    private fun max(a: Int, b: Int) = if (a > b) a else b
}
