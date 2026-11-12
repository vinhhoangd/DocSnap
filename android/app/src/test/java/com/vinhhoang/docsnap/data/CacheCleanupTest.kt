package com.vinhhoang.docsnap.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class CacheCleanupTest {
    @get:Rule val tmp = TemporaryFolder()

    private val now = 1_800_000_000_000L
    private val hour = 60 * 60 * 1000L

    private fun File.aged(ms: Long) = apply { setLastModified(now - ms) }

    /** An export folder (one per share) holding a PDF, both last touched `ageMs` ago. */
    private fun share(exports: File, name: String, ageMs: Long): File {
        val folder = File(exports, name).apply { mkdirs() }
        File(folder, "Hóa đơn.pdf").apply { writeText("%PDF") }.aged(ageMs)
        return folder.aged(ageMs)
    }

    @Test fun aFileSharedRecentlySurvivesLaunch() {
        // Regression: launch used to wipe cache/exports, so Zalo reading a just-shared PDF after
        // Samsung killed DocSnap cold-started the app and found the file gone.
        val exports = tmp.newFolder("exports")
        val fresh = share(exports, "fresh", 5 * 60 * 1000L)
        val yesterdayish = share(exports, "23h", 23 * hour)
        val old = share(exports, "old", 25 * hour)

        assertEquals(1, CacheCleanup.deleteOlderThan(exports, CacheCleanup.EXPORT_MAX_AGE_MS, now))
        assertTrue(File(fresh, "Hóa đơn.pdf").exists())
        assertTrue(yesterdayish.exists())
        assertFalse(old.exists())
    }

    @Test fun aFolderWithARecentFileIsKeptEvenIfTheFolderLooksOld() {
        val exports = tmp.newFolder("exports")
        val folder = File(exports, "mixed").apply { mkdirs() }
        File(folder, "a.jpg").apply { writeText("a") }.aged(30 * hour)
        File(folder, "b.jpg").apply { writeText("b") }.aged(hour)
        folder.aged(30 * hour)
        assertEquals(0, CacheCleanup.deleteOlderThan(exports, CacheCleanup.EXPORT_MAX_AGE_MS, now))
        assertTrue(File(folder, "a.jpg").exists())
    }

    @Test fun scanHandOffsAreKeptForAnHour() {
        val scans = tmp.newFolder("scans")
        val saving = File(scans, "new.jpg").apply { writeText("x") }.aged(10 * 60 * 1000L)
        val abandoned = File(scans, "old.jpg").apply { writeText("x") }.aged(2 * hour)
        assertEquals(1, CacheCleanup.deleteOlderThan(scans, CacheCleanup.SCAN_MAX_AGE_MS, now))
        assertTrue(saving.exists())
        assertFalse(abandoned.exists())
    }

    @Test fun aMissingFolderIsFine() {
        assertEquals(0, CacheCleanup.deleteOlderThan(File(tmp.root, "nope"), CacheCleanup.EXPORT_MAX_AGE_MS, now))
    }
}
