package com.vinhhoang.docsnap.processing

import com.vinhhoang.docsnap.model.ScanFilter

/**
 * Pure-Kotlin page filters on ARGB pixels (no Android types, so they run in JVM unit tests).
 * Port of the iPhone app's ImageProcessor: Magic Color, Grayscale, B&W, Lighten.
 */
object ImageFilters {
    /** Returns a new ARGB array; `pixels` is not modified. */
    fun apply(filter: ScanFilter, pixels: IntArray, width: Int, height: Int): IntArray {
        require(pixels.size == width * height) { "pixel count must match the size" }
        // STUB (processing agent)
        return pixels.copyOf()
    }
}
