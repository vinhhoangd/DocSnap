package com.vinhhoang.docsnap.ui.common

import com.vinhhoang.docsnap.data.DocumentStore
import com.vinhhoang.docsnap.model.ScanFilter
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class PageOrderTest {
    @get:Rule val temp = TemporaryFolder()

    @Test fun moveLeftAndRightInTheMiddle() {
        assertEquals(1, PageOrder.target(2, -1, 5))
        assertEquals(3, PageOrder.target(2, +1, 5))
    }

    @Test fun firstPageCantMoveLeft() {
        assertNull(PageOrder.target(0, -1, 5))
        assertFalse(PageOrder.canMoveLeft(0, 5))
        assertTrue(PageOrder.canMoveRight(0, 5))
    }

    @Test fun lastPageCantMoveRight() {
        assertNull(PageOrder.target(4, +1, 5))
        assertFalse(PageOrder.canMoveRight(4, 5))
        assertTrue(PageOrder.canMoveLeft(4, 5))
    }

    @Test fun singlePageCantMove() {
        assertFalse(PageOrder.canMoveLeft(0, 1))
        assertFalse(PageOrder.canMoveRight(0, 1))
    }

    @Test fun outOfRangeIndexCantMove() {
        assertNull(PageOrder.target(-1, +1, 3))
        assertNull(PageOrder.target(3, -1, 3))
        assertNull(PageOrder.target(0, +1, 0))
    }

    @Test fun zeroStepIsNoMove() {
        assertNull(PageOrder.target(1, 0, 3))
    }

    @Test fun movedSwapsNeighbours() {
        assertEquals(listOf("a", "c", "b", "d"), PageOrder.moved(listOf("a", "b", "c", "d"), 1, 2))
        assertEquals(listOf("b", "a", "c", "d"), PageOrder.moved(listOf("a", "b", "c", "d"), 1, 0))
    }

    @Test fun movedClampsTarget() {
        assertEquals(listOf("b", "c", "a"), PageOrder.moved(listOf("a", "b", "c"), 0, 99))
        assertEquals(listOf("c", "a", "b"), PageOrder.moved(listOf("a", "b", "c"), 2, -5))
    }

    @Test fun movedIgnoresBadSource() {
        assertEquals(listOf("a", "b"), PageOrder.moved(listOf("a", "b"), 5, 0))
    }

    @Test fun matchesTheStoreForEveryMove() = runBlocking {
        val store = DocumentStore(temp.newFolder("docs"), { original, _, output -> original.copyTo(output, true) }, Dispatchers.Unconfined)
        val images = (1..4).map { i -> temp.newFile("p$i.jpg").apply { writeBytes(byteArrayOf(i.toByte())) } }
        val doc = store.createDocument(images, ScanFilter.Original)
        var expected = doc.pages.map { it.id }
        for (from in 0 until 4) {
            for (step in listOf(-1, +1)) {
                val to = PageOrder.target(from, step, 4) ?: continue
                store.movePage(doc.id, from, to)
                expected = PageOrder.moved(expected, from, to)
                assertEquals("from=$from step=$step", expected, store.document(doc.id)!!.pages.map { it.id })
            }
        }
    }
}
