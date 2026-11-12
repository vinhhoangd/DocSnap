package com.vinhhoang.docsnap.ui.document

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class BusyGateTest {
    @Test fun aSecondTapJobWhileBusyIsIgnored() {
        val gate = BusyGate<String>()
        assertTrue(gate.tryStart("pdf"))
        assertFalse(gate.tryStart("images"))
        assertEquals("pdf", gate.busy.value)
        gate.finish()
        assertNull(gate.busy.value)
        assertTrue(gate.tryStart("images"))
    }

    /** The bug: pages scanned while a PDF was being made were deleted without a word. */
    @Test fun savingPagesWaitsForTheRunningJobInsteadOfBeingDropped() = runTest {
        val gate = BusyGate<String>()
        assertTrue(gate.tryStart("pdf"))
        var saved = false
        launch {
            gate.awaitStart("saving")
            saved = true
            gate.finish()
        }
        runCurrent()
        assertFalse(saved)
        assertEquals("pdf", gate.busy.value)

        gate.finish()
        runCurrent()
        assertTrue(saved)
        assertNull(gate.busy.value)
    }

    @Test fun twoWaitingSavesRunOneAfterTheOther() = runTest {
        val gate = BusyGate<String>()
        assertTrue(gate.tryStart("pdf"))
        val order = mutableListOf<String>()
        repeat(2) { i ->
            launch {
                gate.awaitStart("saving-$i")
                order += "start-$i"
                assertEquals("saving-$i", gate.busy.value)
                kotlinx.coroutines.yield()
                order += "end-$i"
                gate.finish()
            }
        }
        runCurrent()
        gate.finish()
        runCurrent()
        assertEquals(listOf("start-0", "end-0", "start-1", "end-1"), order)
        assertNull(gate.busy.value)
    }

    @Test fun awaitStartWhenIdleStartsAtOnce() = runTest {
        val gate = BusyGate<String>()
        gate.awaitStart("saving")
        assertEquals("saving", gate.busy.value)
        assertFalse(gate.tryStart("pdf"))
    }
}
