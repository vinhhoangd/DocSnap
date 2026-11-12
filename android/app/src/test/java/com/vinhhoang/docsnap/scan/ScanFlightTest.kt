package com.vinhhoang.docsnap.scan

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** A double tap on Scan must open the scanner once. */
class ScanFlightTest {
    @Test fun secondTapWhileOpeningIsIgnored() {
        val flight = ScanFlight()
        assertTrue(flight.begin())
        assertTrue(flight.opening.value)
        assertFalse(flight.begin())
    }

    @Test fun canScanAgainAfterTheScannerCloses() {
        val flight = ScanFlight()
        assertTrue(flight.begin())
        flight.end() // result, cancel or failure
        assertFalse(flight.opening.value)
        assertTrue(flight.begin())
    }

    @Test fun noNewScanWhileThePreviousIsBeingCopied() {
        val flight = ScanFlight()
        assertTrue(flight.begin())
        flight.end()
        flight.setImporting(true)
        assertFalse(flight.begin())
        flight.setImporting(false)
        assertTrue(flight.begin())
    }
}
