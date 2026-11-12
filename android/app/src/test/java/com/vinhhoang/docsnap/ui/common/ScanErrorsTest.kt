package com.vinhhoang.docsnap.ui.common

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ScanErrorsTest {
    @Test fun playServicesOkMeansLaunch() = assertNull(ScanErrors.forPlayServicesStatus(0))

    @Test fun playServicesMissingOrInvalid() {
        assertEquals(ScanErrorKind.PlayServicesMissing, ScanErrors.forPlayServicesStatus(1))
        assertEquals(ScanErrorKind.PlayServicesMissing, ScanErrors.forPlayServicesStatus(9))
    }

    @Test fun playServicesOutdatedOrDisabled() {
        assertEquals(ScanErrorKind.PlayServicesUpdate, ScanErrors.forPlayServicesStatus(2))
        assertEquals(ScanErrorKind.PlayServicesUpdate, ScanErrors.forPlayServicesStatus(3))
    }

    @Test fun playServicesUpdatingMeansWait() =
        assertEquals(ScanErrorKind.Downloading, ScanErrors.forPlayServicesStatus(18))

    @Test fun unknownStatusIsTreatedAsMissing() =
        assertEquals(ScanErrorKind.PlayServicesMissing, ScanErrors.forPlayServicesStatus(42))

    @Test fun moduleStillDownloading() {
        assertEquals(ScanErrorKind.Downloading, ScanErrors.forException(14, null))
        assertEquals(ScanErrorKind.Downloading, ScanErrors.forException(null, "Waiting for the document scanner module to be downloaded."))
        assertEquals(ScanErrorKind.Downloading, ScanErrors.forException(13, "Failed to load optional module"))
    }

    @Test fun playServicesTooOld() {
        assertEquals(ScanErrorKind.PlayServicesUpdate, ScanErrors.forException(207, "anything"))
        assertEquals(ScanErrorKind.PlayServicesUpdate, ScanErrors.forException(null, "Google Play services version too old"))
    }

    @Test fun noSpace() = assertEquals(ScanErrorKind.NoSpace, ScanErrors.forException(101, null))

    @Test fun otherFailuresAreGeneric() {
        assertEquals(ScanErrorKind.Generic, ScanErrors.forException(null, null))
        assertEquals(ScanErrorKind.Generic, ScanErrors.forException(13, "Internal error"))
    }

    /** "Update Play services" is not a dead end: its message gets an Update button. */
    @Test fun onlyTheUpdateErrorOffersTheStore() {
        assertEquals(true, ScanErrors.offersPlayServicesUpdate(ScanErrorKind.PlayServicesUpdate))
        ScanErrorKind.entries.filter { it != ScanErrorKind.PlayServicesUpdate }.forEach {
            assertEquals(it.name, false, ScanErrors.offersPlayServicesUpdate(it))
        }
        // Both ways of hearing "too old" lead to the button.
        assertEquals(true, ScanErrors.offersPlayServicesUpdate(ScanErrors.forException(207, null)))
        assertEquals(true, ScanErrors.offersPlayServicesUpdate(ScanErrors.forPlayServicesStatus(2)!!))
    }
}
