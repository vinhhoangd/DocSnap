package com.vinhhoang.docsnap.processing

import com.vinhhoang.docsnap.model.TextLine
import com.vinhhoang.docsnap.ocr.ReadingOrder
import org.junit.Assert.assertEquals
import org.junit.Test
import java.util.Random

/** OCR reading order (ocr/ReadingOrder.kt); kept here with the other processing tests. */
class ReadingOrderTest {
    private fun line(text: String, left: Float, top: Float, height: Float = 0.02f, width: Float = 0.2f) =
        TextLine(text, left, top, width, height)

    @Test fun emptyAndSingle() {
        assertEquals(emptyList<TextLine>(), ReadingOrder.sort(emptyList()))
        val one = listOf(line("a", 0.1f, 0.1f))
        assertEquals(one, ReadingOrder.sort(one))
    }

    @Test fun topToBottom() {
        val lines = listOf(line("third", 0.1f, 0.5f), line("first", 0.1f, 0.1f), line("second", 0.1f, 0.3f))
        assertEquals(listOf("first", "second", "third"), ReadingOrder.sort(lines).map { it.text })
    }

    @Test fun leftToRightWithinARow() {
        // "Họ và tên:" label and its value on one row, the value box sitting slightly higher.
        val lines = listOf(
            line("Nguyễn Văn A", 0.4f, 0.198f),
            line("Họ và tên:", 0.1f, 0.2f),
            line("Ngày sinh:", 0.1f, 0.25f),
        )
        assertEquals(listOf("Họ và tên:", "Nguyễn Văn A", "Ngày sinh:"), ReadingOrder.sort(lines).map { it.text })
    }

    @Test fun separateRowsAreNotMerged() {
        val lines = listOf(line("b", 0.1f, 0.13f), line("a", 0.5f, 0.1f))
        assertEquals(listOf("a", "b"), ReadingOrder.sort(lines).map { it.text })
    }

    @Test fun keepsEveryLine() {
        val rnd = Random(3)
        val lines = List(500) { line("l$it", rnd.nextFloat(), rnd.nextFloat(), 0.005f + rnd.nextFloat() * 0.05f) }
        val sorted = ReadingOrder.sort(lines)
        assertEquals(lines.toSet(), sorted.toSet())
        assertEquals(lines.size, sorted.size)
    }

    /** The pairwise iOS comparator is not transitive; grouping must not depend on that. */
    @Test fun denseOverlappingLinesDoNotBreakSorting() {
        val rnd = Random(11)
        repeat(20) {
            val lines = List(300) { line("l$it", rnd.nextFloat(), 0.5f + rnd.nextFloat() * 0.05f, 0.01f + rnd.nextFloat() * 0.03f) }
            assertEquals(300, ReadingOrder.sort(lines).size)
        }
    }
}
