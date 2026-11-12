package com.vinhhoang.docsnap.ui.common

/** Decode-size math for page images (pure, so it runs in JVM tests). */
object ImageSampling {
    /**
     * The smallest power-of-two `inSampleSize` whose decoded image has its longest side at most
     * `maxSide` (BitmapFactory only samples by powers of two, and rounds partial pixels up).
     * 1 when the image is already small enough.
     */
    fun inSampleSize(width: Int, height: Int, maxSide: Int): Int {
        if (width <= 0 || height <= 0 || maxSide <= 0) return 1
        val longest = maxOf(width, height)
        var sample = 1
        while (ceilDiv(longest, sample) > maxSide) sample *= 2
        return sample
    }

    /**
     * The exact size to decode to (ImageDecoder.setTargetSize): scaled down to fit `maxSide` on the
     * longest side, aspect ratio kept, never scaled up, never 0.
     */
    fun targetSize(width: Int, height: Int, maxSide: Int): Pair<Int, Int> {
        if (width <= 0 || height <= 0 || maxSide <= 0) return maxOf(width, 1) to maxOf(height, 1)
        val longest = maxOf(width, height)
        if (longest <= maxSide) return width to height
        // Integer math, rounded: 3024 × 2560 / 4032 is exactly 1920, not 1919.999….
        fun scaled(side: Int) = ((side.toLong() * maxSide + longest / 2) / longest).toInt().coerceIn(1, maxSide)
        return scaled(width) to scaled(height)
    }

    /** Bytes of an ARGB_8888 bitmap of this size. */
    fun argbBytes(width: Int, height: Int): Long = width.toLong() * height.toLong() * 4

    /**
     * How much memory the decoded-page cache may use: a sixth of the app's heap, capped at 64 MB.
     * A low-RAM Samsung (192–256 MB heap) gets 32–42 MB: plenty of thumbnails, not many full pages.
     */
    fun cacheBytes(maxHeapBytes: Long): Long = (maxHeapBytes / 6).coerceIn(4L * MB, 64L * MB)

    /**
     * Whether a bitmap is small enough to cache. One that takes more than a quarter of the cache
     * would push out most of the thumbnails, so it is only kept while it's on screen.
     */
    fun fitsCache(bitmapBytes: Long, cacheBytes: Long): Boolean = bitmapBytes in 1..cacheBytes / 4

    /**
     * Longest side the full-screen viewer decodes. 2560 px gives a sharp 2.5× zoom on a phone; a
     * phone with a small heap (≤ 256 MB) gets 2048 px so three pager pages (~12 MB each) still fit.
     */
    fun viewerMaxSide(maxHeapBytes: Long): Int = if (maxHeapBytes <= 256L * MB) 2048 else 2560

    /** Cache key: the same file at a new version (after a filter or rotation) is a different image. */
    fun cacheKey(path: String, version: Int, maxSide: Int) = "$path#v$version@$maxSide"

    private fun ceilDiv(a: Int, b: Int) = (a + b - 1) / b

    private const val MB = 1024L * 1024L
}
