package com.vinhhoang.docsnap.ocr

import com.vinhhoang.docsnap.model.TextLine
import kotlin.math.abs
import kotlin.math.min

/**
 * Sorts OCR lines top-to-bottom, then left-to-right within a row (same rule as the iPhone app:
 * lines whose centres are within half a line height share a row).
 *
 * Lines are grouped into rows first and then sorted, rather than sorted with a pairwise
 * "same row?" comparator: that comparator isn't transitive, and Java's TimSort can throw
 * "Comparison method violates its general contract" on it.
 */
object ReadingOrder {
    fun sort(lines: List<TextLine>): List<TextLine> {
        if (lines.size < 2) return lines
        val rows = mutableListOf<Row>()
        for (line in lines.sortedWith(compareBy<TextLine> { it.top + it.height / 2 }.thenBy { it.left })) {
            val mid = line.top + line.height / 2
            val row = rows.lastOrNull()
            if (row != null && abs(mid - row.mid) <= min(line.height, row.minHeight) * 0.5f) row.add(line) else rows += Row(line)
        }
        return rows.flatMap { row -> row.lines.sortedBy { it.left } }
    }

    private class Row(first: TextLine) {
        val lines = mutableListOf(first)
        var mid = first.top + first.height / 2
            private set
        var minHeight = first.height
            private set

        fun add(line: TextLine) {
            lines += line
            mid = lines.sumOf { (it.top + it.height / 2).toDouble() }.toFloat() / lines.size
            minHeight = min(minHeight, line.height)
        }
    }
}
