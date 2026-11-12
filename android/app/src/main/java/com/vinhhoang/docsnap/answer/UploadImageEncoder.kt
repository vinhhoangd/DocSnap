package com.vinhhoang.docsnap.answer

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import androidx.exifinterface.media.ExifInterface
import com.vinhhoang.docsnap.processing.PageRenderer
import java.io.ByteArrayOutputStream
import java.io.File
import kotlin.math.max
import kotlin.math.roundToInt

/** Turns a page image file into JPEG bytes whose base64 fits `maxBase64Chars`; null if it can't be read. */
fun interface UploadImageEncoder {
    fun encode(image: File, maxBase64Chars: Int): ByteArray?
}

/** The size/quality ladder, kept apart from Bitmap code so it is JVM-testable. */
object UploadSizing {
    /** Longest side and JPEG quality, tried in order until the base64 fits. */
    val steps: List<Pair<Int, Int>> = listOf(
        2048 to 85,
        2048 to 75,
        1600 to 75,
        1280 to 70,
        1024 to 65,
    )

    /**
     * Returns the first encoding from [steps] that fits, or the last one tried if none fit (the client then
     * reports `image_too_large`). `encodeAt(longestSide, quality)` returns null when the image can't be read.
     */
    fun fit(maxBase64Chars: Int, encodeAt: (longestSide: Int, quality: Int) -> ByteArray?): ByteArray? {
        var last: ByteArray? = null
        for ((side, quality) in steps) {
            val bytes = encodeAt(side, quality) ?: return null
            if (AnswerClient.base64Length(bytes.size) <= maxBase64Chars) return bytes
            last = bytes
        }
        return last
    }

    /** Largest power-of-two sample size that still leaves the longest side ≥ `target`. */
    fun sampleSize(longestSide: Int, target: Int): Int {
        var sample = 1
        while (longestSide / (sample * 2) >= target) sample *= 2
        return sample
    }
}

/** Android implementation: decode with subsampling (12 MP pages stay small in memory), honour EXIF, scale, JPEG. */
object BitmapUploadEncoder : UploadImageEncoder {
    override fun encode(image: File, maxBase64Chars: Int): ByteArray? {
        if (!image.isFile) return null
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(image.path, bounds)
        val longest = max(bounds.outWidth, bounds.outHeight)
        if (longest <= 0) return null
        val firstSide = UploadSizing.steps.first().first
        val decoded = BitmapFactory.decodeFile(
            image.path,
            BitmapFactory.Options().apply {
                inSampleSize = UploadSizing.sampleSize(longest, firstSide)
                // Claude reads the JPEG as sRGB; convert wide-gamut (Display P3) photos.
                inPreferredColorSpace = PageRenderer.SRGB
            },
        ) ?: return null
        val upright = applyExif(image, decoded)
        try {
            return UploadSizing.fit(maxBase64Chars) { side, quality -> jpeg(upright, side, quality) }
        } finally {
            upright.recycle()
        }
    }

    /** The image at `longestSide` as JPEG bytes, or null if encoding fails. */
    private fun jpeg(source: Bitmap, longestSide: Int, quality: Int): ByteArray? {
        val longest = max(source.width, source.height)
        val bitmap = if (longest > longestSide) {
            val scale = longestSide.toFloat() / longest
            Bitmap.createScaledBitmap(
                source,
                (source.width * scale).roundToInt().coerceAtLeast(1),
                (source.height * scale).roundToInt().coerceAtLeast(1),
                true,
            )
        } else {
            source
        }
        try {
            val out = ByteArrayOutputStream()
            // A failed encode would otherwise send a truncated (or empty) image.
            if (!bitmap.compress(Bitmap.CompressFormat.JPEG, quality, out)) return null
            return out.toByteArray()
        } finally {
            if (bitmap !== source) bitmap.recycle()
        }
    }

    /** Applies the EXIF orientation, all eight cases (mirrored and transposed ones too). */
    private fun applyExif(file: File, bitmap: Bitmap): Bitmap {
        val orientation = runCatching {
            ExifInterface(file.path).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)
        }.getOrDefault(ExifInterface.ORIENTATION_NORMAL)
        if (PageRenderer.isUpright(orientation)) return bitmap
        val matrix = PageRenderer.orientationMatrix(orientation)
        if (matrix.isIdentity) return bitmap
        val upright = try {
            Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
        } catch (e: Throwable) {
            bitmap.recycle()
            throw e
        }
        if (upright !== bitmap) bitmap.recycle()
        return upright
    }
}
