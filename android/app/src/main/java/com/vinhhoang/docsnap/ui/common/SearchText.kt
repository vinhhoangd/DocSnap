package com.vinhhoang.docsnap.ui.common

import java.text.Normalizer
import java.util.Locale

/**
 * Search that ignores case and Vietnamese accents, so "hoa don" finds "Hóa đơn" (the iPhone app
 * searches case- and diacritic-insensitively too). Every word of the query must appear somewhere.
 */
object SearchText {
    private val marks = Regex("\\p{Mn}+")
    private val spaces = Regex("\\s+")

    /** Lowercase, accents removed, đ → d. */
    fun fold(text: String): String {
        val noD = text.replace('đ', 'd').replace('Đ', 'D')
        return marks.replace(Normalizer.normalize(noD, Normalizer.Form.NFD), "").lowercase(Locale.ROOT)
    }

    /** The query's words, folded. Empty when the query is blank. */
    fun terms(query: String): List<String> = fold(query).trim().split(spaces).filter { it.isNotEmpty() }

    /** True when every term occurs in `foldedText` (text already passed through [fold]). */
    fun matchesFolded(terms: List<String>, foldedText: String): Boolean = terms.all { foldedText.contains(it) }

    fun matches(query: String, vararg fields: String?): Boolean {
        val terms = terms(query)
        if (terms.isEmpty()) return true
        return matchesFolded(terms, fold(fields.filterNotNull().joinToString("\n")))
    }
}
