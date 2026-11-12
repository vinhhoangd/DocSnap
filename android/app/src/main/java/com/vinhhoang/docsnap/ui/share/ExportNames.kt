package com.vinhhoang.docsnap.ui.share

/** File names for shared exports. Vietnamese letters are kept; characters apps or file systems reject are not. */
object ExportNames {
    const val FALLBACK = "DocSnap"
    private const val MAX_LENGTH = 80
    private val illegal = Regex("[\\\\/:*?\"<>|\\p{Cntrl}]")
    private val spaces = Regex("\\s+")

    /** A safe base name (no extension) from a document title. */
    fun safeBaseName(title: String): String {
        val cleaned = illegal.replace(title, " ").replace(spaces, " ").trim().trim('.').trim()
        val cut = if (cleaned.length > MAX_LENGTH) cleaned.take(MAX_LENGTH).trimEnd() else cleaned
        return cut.ifEmpty { FALLBACK }
    }

    /** "Title - 01.jpg"; zero-padded to at least 2 digits, more for 100+ pages, so apps sort them right. */
    fun imageName(base: String, index: Int, count: Int): String {
        val width = maxOf(2, count.toString().length)
        return "$base - ${(index + 1).toString().padStart(width, '0')}.jpg"
    }

    fun pdfName(base: String) = "$base.pdf"

    fun textName(base: String) = "$base.txt"
}
