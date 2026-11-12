package com.vinhhoang.docsnap.ui.common

/** Decode-size math for page images (pure, so it runs in JVM tests). */
object ImageSampling {
    /**
     * The largest power-of-two `inSampleSize` that keeps the decoded image's longest side at or above
     * `maxSide` (BitmapFactory rounds down to a power of two anyway). 1 when the image is already small.
     */
    fun inSampleSize(width: Int, height: Int, maxSide: Int): Int {
        if (width <= 0 || height <= 0 || maxSide <= 0) return 1
        val longest = maxOf(width, height)
        var sample = 1
        while (longest / (sample * 2) >= maxSide) sample *= 2
        return sample
    }

    /** Cache key: the same file at a new version (after a filter or rotation) is a different image. */
    fun cacheKey(path: String, version: Int, maxSide: Int) = "$path#v$version@$maxSide"
}
