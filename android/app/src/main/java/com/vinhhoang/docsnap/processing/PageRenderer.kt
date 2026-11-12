package com.vinhhoang.docsnap.processing

import com.vinhhoang.docsnap.model.ScanPage
import java.io.File

/**
 * Turns a page's original image into the processed one: rotation, then `page.filter` (see ImageFilters).
 * Must cap memory on 12+ MP images and write a high-quality JPEG (quality ≈ 92) to `output`.
 */
object PageRenderer {
    /** Longest side kept for originals and processed pages. */
    const val MAX_DIMENSION = 4096
    const val JPEG_QUALITY = 92

    fun render(original: File, page: ScanPage, output: File) {
        // STUB (processing agent): copy until filters exist.
        original.copyTo(output, overwrite = true)
    }
}
