package com.vinhhoang.docsnap.answer

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import androidx.exifinterface.media.ExifInterface
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
            BitmapFactory.Options().apply { inSampleSize = UploadSizing.sampleSize(longest, firstSide) },
        ) ?: return null
        val upright = applyExif(image, decoded)
        try {
            return UploadSizing.fit(maxBase64Chars) { side, quality -> jpeg(upright, side, quality) }
        } finally {
            upright.recycle()
        }
    }

    private fun jpeg(source: Bitmap, longestSide: Int, quality: Int): ByteArray {
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
        val out = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.JPEG, quality, out)
        if (bitmap !== source) bitmap.recycle()
        return out.toByteArray()
    }

    private fun applyExif(file: File, bitmap: Bitmap): Bitmap {
        val orientation = runCatching {
            ExifInterface(file.path).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)
        }.getOrDefault(ExifInterface.ORIENTATION_NORMAL)
        val degrees = when (orientation) {
            ExifInterface.ORIENTATION_ROTATE_90 -> 90f
            ExifInterface.ORIENTATION_ROTATE_180 -> 180f
            ExifInterface.ORIENTATION_ROTATE_270 -> 270f
            else -> return bitmap
        }
        val rotated = Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, Matrix().apply { postRotate(degrees) }, true)
        if (rotated !== bitmap) bitmap.recycle()
        return rotated
    }
}
