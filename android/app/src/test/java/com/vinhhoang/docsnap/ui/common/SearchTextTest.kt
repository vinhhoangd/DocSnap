package com.vinhhoang.docsnap.ui.common

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SearchTextTest {
    @Test fun foldRemovesVietnameseAccentsAndCase() {
        assertEquals("hoa don", SearchText.fold("Hóa đơn"))
        assertEquals("dien nuoc thang 11", SearchText.fold("ĐIỆN NƯỚC Tháng 11"))
        assertEquals("tieng viet co dau", SearchText.fold("Tiếng Việt có dấu"))
    }

    @Test fun foldHandlesStackedTones() {
        // Each of these has a vowel mark plus a tone mark.
        assertEquals("aaaeeeooouu", SearchText.fold("ắẩậếềểốờởữự"))
    }

    @Test fun foldHandlesPrecomposedAndDecomposedInput() {
        val decomposed = "Hoá đơn" // "ó" written as o + combining acute
        assertEquals(SearchText.fold("Hóa đơn"), SearchText.fold(decomposed))
    }

    @Test fun unaccentedQueryFindsAccentedTitle() {
        assertTrue(SearchText.matches("hoa don", "Hóa đơn"))
        assertTrue(SearchText.matches("HOA DON", "Hóa đơn tiền điện"))
    }

    @Test fun accentedQueryFindsUnaccentedText() {
        assertTrue(SearchText.matches("Hóa đơn", "hoa don thang 11"))
    }

    @Test fun dMatchesDStroke() {
        assertTrue(SearchText.matches("dien", "Điện"))
        assertTrue(SearchText.matches("đien", "DIEN"))
    }

    @Test fun everyWordMustAppearInAnyOrder() {
        assertTrue(SearchText.matches("don hoa", "Hóa đơn"))
        assertFalse(SearchText.matches("hoa nuoc", "Hóa đơn"))
    }

    @Test fun wordsMaySpanTitleAndOcrText() {
        assertTrue(SearchText.matches("scan tong cong", "Scan 2026-11-12", "TỔNG CỘNG: 250.000đ"))
    }

    @Test fun nullFieldsAreIgnored() {
        assertTrue(SearchText.matches("bill", null, "Electricity bill"))
        assertFalse(SearchText.matches("bill", null, null))
    }

    @Test fun blankQueryMatchesEverything() {
        assertTrue(SearchText.matches("", "anything"))
        assertTrue(SearchText.matches("   ", "anything"))
        assertTrue(SearchText.terms(" \t ").isEmpty())
    }

    @Test fun extraSpacesInQueryDontMatter() {
        assertEquals(listOf("hoa", "don"), SearchText.terms("  Hóa    đơn  "))
    }

    @Test fun partialWordsMatch() {
        assertTrue(SearchText.matches("hoa d", "Hóa đơn"))
        assertTrue(SearchText.matches("2026-11", "Scan 2026-11-12 14.30"))
    }

    @Test fun noMatch() {
        assertFalse(SearchText.matches("receipt", "Hóa đơn", "điện nước"))
    }

    @Test fun matchesFoldedUsesPrefoldedText() {
        val folded = SearchText.fold("Bài tập Đại số tuyến tính")
        assertTrue(SearchText.matchesFolded(SearchText.terms("dai so"), folded))
        assertFalse(SearchText.matchesFolded(SearchText.terms("giai tich"), folded))
    }
}
