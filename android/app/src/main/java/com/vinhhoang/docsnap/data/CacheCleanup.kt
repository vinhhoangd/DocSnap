package com.vinhhoang.docsnap.data

import java.io.File

/**
 * Age-based cleanup of the app's temporary folders.
 *
 * Nothing is wiped wholesale at launch: a shared PDF lives in cache/exports while the receiving app
 * (Zalo, Gmail, …) still holds its content:// URI, and that app reading it is what cold-starts
 * DocSnap after Samsung has killed it. Scanner hand-offs in cache/scans are kept while a save might
 * still be copying from them.
 */
object CacheCleanup {
    /** Shared files stay readable by the receiving app for a day. */
    const val EXPORT_MAX_AGE_MS = 24 * 60 * 60 * 1000L

    /** Scanner hand-offs are copied into the store within seconds; an hour old means abandoned. */
    const val SCAN_MAX_AGE_MS = 60 * 60 * 1000L

    /**
     * Deletes each direct child of `dir` (a file, or a folder with everything in it) whose newest
     * modification time is older than `maxAgeMs`. Returns how many were deleted.
     */
    fun deleteOlderThan(dir: File, maxAgeMs: Long, now: Long = System.currentTimeMillis()): Int {
        val cutoff = now - maxAgeMs
        var deleted = 0
        dir.listFiles().orEmpty().forEach { entry ->
            if (newestModification(entry) < cutoff && entry.deleteRecursively()) deleted++
        }
        return deleted
    }

    private fun newestModification(file: File): Long =
        if (file.isDirectory) {
            file.listFiles().orEmpty().fold(file.lastModified()) { newest, child -> maxOf(newest, newestModification(child)) }
        } else {
            file.lastModified()
        }
}
