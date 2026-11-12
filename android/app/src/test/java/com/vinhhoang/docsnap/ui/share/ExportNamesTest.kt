package com.vinhhoang.docsnap.ui.share

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ExportNamesTest {
    @Test fun plainTitleIsKept() = assertEquals("Scan 2026-11-12 14.30", ExportNames.safeBaseName("Scan 2026-11-12 14.30"))

    @Test fun vietnameseLettersAreKept() = assertEquals("Hóa đơn tiền điện", ExportNames.safeBaseName("Hóa đơn tiền điện"))

    @Test fun pathAndReservedCharactersBecomeSpaces() {
        assertEquals("a b c d e f g h i", ExportNames.safeBaseName("a/b\\c:d*e?f\"g<h>i"))
        assertEquals("Bill 11 2026", ExportNames.safeBaseName("Bill 11/2026"))
        assertEquals("x y", ExportNames.safeBaseName("x|y"))
    }

    @Test fun controlCharactersAndNewlinesAreRemoved() =
        assertEquals("line one line two", ExportNames.safeBaseName("line one\nline two\t\u0000"))

    @Test fun spacesCollapseAndTrim() = assertEquals("a b", ExportNames.safeBaseName("   a     b   "))

    @Test fun leadingAndTrailingDotsAreDropped() {
        assertEquals("hidden", ExportNames.safeBaseName(".hidden"))
        assertEquals("name", ExportNames.safeBaseName("name..."))
    }

    @Test fun emptyOrOnlyIllegalFallsBack() {
        assertEquals(ExportNames.FALLBACK, ExportNames.safeBaseName(""))
        assertEquals(ExportNames.FALLBACK, ExportNames.safeBaseName("   "))
        assertEquals(ExportNames.FALLBACK, ExportNames.safeBaseName("///***"))
        assertEquals(ExportNames.FALLBACK, ExportNames.safeBaseName(".."))
    }

    @Test fun longTitlesAreCut() {
        val name = ExportNames.safeBaseName("x".repeat(300))
        assertEquals(80, name.length)
        val spaced = ExportNames.safeBaseName("word ".repeat(40))
        assertTrue(spaced.length <= 80)
        assertFalse(spaced.endsWith(" "))
    }

    @Test fun imageNamesArePaddedForSorting() {
        assertEquals("Doc - 01.jpg", ExportNames.imageName("Doc", 0, 3))
        assertEquals("Doc - 09.jpg", ExportNames.imageName("Doc", 8, 9))
        assertEquals("Doc - 10.jpg", ExportNames.imageName("Doc", 9, 10))
        assertEquals("Doc - 001.jpg", ExportNames.imageName("Doc", 0, 120))
        assertEquals("Doc - 120.jpg", ExportNames.imageName("Doc", 119, 120))
    }

    @Test fun imageNamesAreUniqueAndSorted() {
        val names = (0 until 50).map { ExportNames.imageName("Hóa đơn", it, 50) }
        assertEquals(50, names.toSet().size)
        assertEquals(names, names.sorted())
    }

    @Test fun pdfAndTextNames() {
        assertEquals("Hóa đơn.pdf", ExportNames.pdfName("Hóa đơn"))
        assertEquals("Hóa đơn.txt", ExportNames.textName("Hóa đơn"))
    }
}
