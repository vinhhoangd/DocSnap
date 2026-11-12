package com.vinhhoang.docsnap.data

import com.vinhhoang.docsnap.model.PageAnswer
import com.vinhhoang.docsnap.model.ScanDocument
import com.vinhhoang.docsnap.model.ScanFilter
import com.vinhhoang.docsnap.model.ScanPage
import com.vinhhoang.docsnap.model.TextLine
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.nio.channels.FileChannel
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.nio.file.StandardOpenOption

/**
 * All documents, stored as files (no database yet — auth and sync come later):
 *
 *     <root>/<documentId>/document.json
 *     <root>/<documentId>/original/<pageId>.jpg    the scanner's page, never modified
 *     <root>/<documentId>/processed/<pageId>.jpg   rotation + filter applied, what is shown and shared
 *
 * Writes are serialized with a mutex; `document.json` is synced to disk and replaced atomically,
 * with the previous version kept as `document.json.bak` (see `write` and `load`).
 * `renderer` turns an original into the processed image; it is injected so JVM tests need no Android.
 */
class DocumentStore(
    val root: File,
    private val renderer: (original: File, page: ScanPage, output: File) -> Unit,
    private val io: CoroutineDispatcher = Dispatchers.IO,
) {
    private val mutex = Mutex()
    private val _documents = MutableStateFlow<List<ScanDocument>>(emptyList())

    /** Newest first (by last change). */
    val documents: StateFlow<List<ScanDocument>> = _documents.asStateFlow()

    private val _loaded = MutableStateFlow(false)
    /** True once `load()` has read the disk, so "document not found" is real, not "not loaded yet". */
    val loaded: StateFlow<Boolean> = _loaded.asStateFlow()

    fun document(id: String): ScanDocument? = _documents.value.firstOrNull { it.id == id }

    fun folder(documentId: String) = File(root, documentId)
    fun originalFile(documentId: String, pageId: String) = File(folder(documentId), "original/$pageId.jpg")
    fun processedFile(documentId: String, pageId: String) = File(folder(documentId), "processed/$pageId.jpg")

    /**
     * Reads every document from disk.
     *  - `document.json` unreadable (e.g. power loss): the newest good copy is used instead
     *    (`document.json.tmp`, then `.bak`), with any page files it doesn't know appended.
     *  - No readable JSON at all but page images present (the app was killed mid-`createDocument`):
     *    the document is rebuilt from `original/` with a default title and Magic Color.
     *  - Page files no document references (left by an interrupted `addPages`) are deleted.
     * Other unreadable folders are skipped, never deleted.
     */
    suspend fun load() = withContext(io) {
        mutex.withLock {
            root.mkdirs()
            val docs = mutableListOf<ScanDocument>()
            val unsaved = mutableListOf<File>()
            root.listFiles { f -> f.isDirectory }.orEmpty().forEach { dir ->
                when (val stored = readStored(dir)) {
                    is Stored.Found -> if (stored.primary) {
                        runCatching { sweepOrphanPageFiles(stored.doc) }
                        docs += stored.doc
                    } else {
                        docs += runCatching { restore(dir, stored.doc) }.getOrDefault(stored.doc)
                    }
                    Stored.Mismatch -> Unit
                    Stored.None -> if (originalImages(dir).isNotEmpty()) unsaved += dir
                }
            }
            publish(docs)
            _loaded.value = true
            // Rebuilding renders every page, so the library is shown first.
            val rebuilt = unsaved.mapNotNull { dir -> runCatching { rebuild(dir) }.getOrNull() }
            if (rebuilt.isNotEmpty()) publish(_documents.value + rebuilt)
        }
    }

    /**
     * Creates a document from scanned page images (JPEG files, e.g. from the scanner's cache).
     * The source files are copied, so the caller may delete them afterwards.
     */
    suspend fun createDocument(images: List<File>, filter: ScanFilter, title: String? = null): ScanDocument = withContext(io) {
        require(images.isNotEmpty()) { "A document needs at least one page" }
        mutex.withLock {
            val now = System.currentTimeMillis()
            val doc = ScanDocument(title = title?.trim()?.takeIf { it.isNotEmpty() } ?: ScanDocument.defaultTitle(now), createdAt = now)
            try {
                val pages = images.map { savePage(doc.id, it, filter) }
                val saved = doc.copy(pages = pages)
                write(saved)
                publish(_documents.value + saved)
                saved
            } catch (e: Throwable) {
                folder(doc.id).deleteRecursively()
                throw e
            }
        }
    }

    /** Appends pages to an existing document. A no-op if the document was deleted meanwhile. */
    suspend fun addPages(documentId: String, images: List<File>, filter: ScanFilter) = withContext(io) {
        mutex.withLock {
            val doc = document(documentId) ?: return@withLock
            val added = mutableListOf<ScanPage>()
            try {
                images.forEach { added += savePage(documentId, it, filter) }
            } catch (e: Throwable) {
                added.forEach { removePageFiles(documentId, it.id) }
                throw e
            }
            commit(doc.copy(pages = doc.pages + added, updatedAt = System.currentTimeMillis()))
        }
    }

    suspend fun rename(documentId: String, title: String) = mutate(documentId) { doc ->
        val clean = title.trim()
        if (clean.isEmpty()) doc else doc.copy(title = clean)
    }

    suspend fun delete(documentId: String) = withContext(io) {
        mutex.withLock {
            folder(documentId).deleteRecursively()
            publish(_documents.value.filterNot { it.id == documentId })
        }
    }

    /** Deletes one page; deleting the last page deletes the document. */
    suspend fun deletePage(documentId: String, pageId: String) = withContext(io) {
        mutex.withLock {
            val doc = document(documentId) ?: return@withLock
            val remaining = doc.pages.filterNot { it.id == pageId }
            if (remaining.size == doc.pages.size) return@withLock
            if (remaining.isEmpty()) {
                folder(documentId).deleteRecursively()
                publish(_documents.value.filterNot { it.id == documentId })
            } else {
                commit(doc.copy(pages = remaining, updatedAt = System.currentTimeMillis()))
                removePageFiles(documentId, pageId)
            }
        }
    }

    /** Moves the page at `from` to index `to` (both clamped). */
    suspend fun movePage(documentId: String, from: Int, to: Int) = mutate(documentId) { doc ->
        if (from !in doc.pages.indices) return@mutate doc
        val pages = doc.pages.toMutableList()
        val page = pages.removeAt(from)
        pages.add(to.coerceIn(0, pages.size), page)
        doc.copy(pages = pages)
    }

    /**
     * Applies `change` to the page as it is when the edit runs (edits are serialized, so two quick
     * rotations rotate twice). If the image-affecting fields changed, the processed image is re-rendered.
     */
    suspend fun editPage(documentId: String, pageId: String, change: (ScanPage) -> ScanPage) = withContext(io) {
        mutex.withLock {
            val doc = document(documentId) ?: return@withLock
            val index = doc.pages.indexOfFirst { it.id == pageId }
            if (index < 0) return@withLock
            val old = doc.pages[index]
            var new = change(old)
            if (new.filter != old.filter || new.rotation != old.rotation) {
                new = old.edited(filter = new.filter, rotation = new.rotation)
                renderer(originalFile(documentId, pageId), new, processedFile(documentId, pageId))
            }
            if (new == old) return@withLock
            commit(doc.copy(pages = doc.pages.toMutableList().also { it[index] = new }, updatedAt = System.currentTimeMillis()))
        }
    }

    /** Stores OCR lines, unless the page changed since recognition started. */
    suspend fun setText(documentId: String, pageId: String, pageVersion: Int, lines: List<TextLine>) =
        updatePageIf(documentId, pageId, pageVersion) { it.copy(textLines = lines) }

    /** Stores Claude's answer, unless the page changed since the answer was requested. */
    suspend fun setAnswer(documentId: String, pageId: String, answer: PageAnswer) =
        updatePageIf(documentId, pageId, answer.pageVersion) { it.copy(answer = answer) }

    // MARK: - Internals

    private suspend fun updatePageIf(documentId: String, pageId: String, version: Int, change: (ScanPage) -> ScanPage) =
        mutate(documentId) { doc ->
            doc.copy(pages = doc.pages.map { if (it.id == pageId && it.version == version) change(it) else it })
        }

    private suspend fun mutate(documentId: String, change: (ScanDocument) -> ScanDocument) = withContext(io) {
        mutex.withLock {
            val doc = document(documentId) ?: return@withLock
            val new = change(doc)
            if (new != doc) commit(new.copy(updatedAt = System.currentTimeMillis()))
        }
    }

    private fun savePage(documentId: String, image: File, filter: ScanFilter): ScanPage {
        val page = ScanPage(filter = filter)
        val original = originalFile(documentId, page.id)
        original.parentFile?.mkdirs()
        processedFile(documentId, page.id).parentFile?.mkdirs()
        try {
            image.copyTo(original, overwrite = true)
            renderer(original, page, processedFile(documentId, page.id))
        } catch (e: Throwable) {
            removePageFiles(documentId, page.id) // don't leave a half-saved page behind
            throw e
        }
        return page
    }

    private fun removePageFiles(documentId: String, pageId: String) {
        originalFile(documentId, pageId).delete()
        processedFile(documentId, pageId).delete()
    }

    /** Writes and publishes a changed document (caller holds the mutex). */
    private fun commit(doc: ScanDocument) {
        if (!folder(doc.id).exists()) return // deleted meanwhile
        write(doc)
        publish(_documents.value.map { if (it.id == doc.id) doc else it })
    }

    /**
     * Writes `document.json` so that a power cut at any moment leaves a readable copy:
     * the new JSON is synced to disk in a temp file, the old one is kept as `.bak`, then the temp
     * file is renamed over the old (atomic), and the folder is synced so the rename survives.
     */
    private fun write(doc: ScanDocument) {
        val dir = folder(doc.id).apply { mkdirs() }
        val target = File(dir, DOCUMENT_JSON)
        val temp = File(dir, DOCUMENT_TMP)
        val backup = File(dir, DOCUMENT_BAK)
        FileOutputStream(temp).use { out ->
            out.write(json.encodeToString(ScanDocument.serializer(), doc).toByteArray(Charsets.UTF_8))
            out.flush()
            out.fd.sync()
        }
        if (target.isFile) {
            // A hard link keeps the old version without a moment where document.json is missing.
            backup.delete()
            runCatching { Files.createLink(backup.toPath(), target.toPath()) }
                .onFailure { runCatching { target.copyTo(backup, overwrite = true) } }
        }
        try {
            Files.move(temp.toPath(), target.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
        } catch (e: IOException) {
            target.delete()
            check(temp.renameTo(target)) { "Couldn't save ${doc.id}" }
        }
        syncDirectory(dir)
    }

    private fun syncDirectory(dir: File) {
        // Linux (Android) can fsync a directory; other systems may refuse, which is harmless.
        runCatching { FileChannel.open(dir.toPath(), StandardOpenOption.READ).use { it.force(true) } }
    }

    private sealed interface Stored {
        /** `primary`: read from document.json itself, not a temp or backup copy. */
        data class Found(val doc: ScanDocument, val primary: Boolean) : Stored
        /** Readable JSON for a different id (e.g. a copied folder): skipped. */
        data object Mismatch : Stored
        data object None : Stored
    }

    /** The newest readable JSON in `dir`: document.json, else the synced temp file, else the backup. */
    private fun readStored(dir: File): Stored {
        var mismatch = false
        for (name in listOf(DOCUMENT_JSON, DOCUMENT_TMP, DOCUMENT_BAK)) {
            val file = File(dir, name)
            if (!file.isFile) continue
            val doc = runCatching { json.decodeFromString<ScanDocument>(file.readText()) }.getOrNull() ?: continue
            if (doc.id != dir.name) {
                mismatch = true
                continue
            }
            return Stored.Found(doc, primary = name == DOCUMENT_JSON)
        }
        return if (mismatch) Stored.Mismatch else Stored.None
    }

    /** The JPEGs in `dir`'s original folder, oldest first (the order the pages were saved in). */
    private fun originalImages(dir: File): List<File> =
        File(dir, "original").listFiles { f -> f.isFile && f.name.endsWith(".jpg") && !f.name.startsWith(".") }
            .orEmpty()
            .sortedWith(compareBy<File>({ it.lastModified() }, { it.name }))

    /**
     * Turns original images that `known` doesn't list into Magic Color pages, rendering each one.
     * A page that can't be rendered (e.g. its copy was cut short) is deleted rather than kept broken.
     */
    private fun recoverPages(dir: File, known: Set<String>): List<ScanPage> =
        originalImages(dir).filter { it.nameWithoutExtension !in known }.mapNotNull { original ->
            val page = ScanPage(id = original.nameWithoutExtension, filter = ScanFilter.MagicColor)
            try {
                renderer(original, page, processedFile(dir.name, page.id))
                page
            } catch (e: Throwable) {
                removePageFiles(dir.name, page.id)
                null
            }
        }

    /** A folder with page images but no readable JSON (killed mid-create): rebuild its document. */
    private fun rebuild(dir: File): ScanDocument? {
        val createdAt = originalImages(dir).minOfOrNull { it.lastModified() }?.takeIf { it > 0 } ?: System.currentTimeMillis()
        val pages = recoverPages(dir, emptySet())
        if (pages.isEmpty()) return null
        val doc = ScanDocument(id = dir.name, title = ScanDocument.defaultTitle(createdAt), createdAt = createdAt, pages = pages)
        File(dir, DOCUMENT_JSON).delete() // unreadable; don't keep it as the backup
        write(doc)
        return doc
    }

    /** document.json was unreadable and an older copy was found: add pages it doesn't know, save it back. */
    private fun restore(dir: File, doc: ScanDocument): ScanDocument {
        val added = recoverPages(dir, doc.pages.mapTo(HashSet()) { it.id })
        val restored = if (added.isEmpty()) doc else doc.copy(pages = doc.pages + added, updatedAt = System.currentTimeMillis())
        File(dir, DOCUMENT_JSON).delete() // unreadable; don't let it replace the good backup
        write(restored)
        return restored
    }

    /** Deletes page images (and leftover render temp files) that `doc` doesn't reference. */
    private fun sweepOrphanPageFiles(doc: ScanDocument) {
        val ids = doc.pages.mapTo(HashSet()) { it.id }
        for (sub in listOf("original", "processed")) {
            File(folder(doc.id), sub).listFiles { f -> f.isFile }.orEmpty().forEach { file ->
                val leftoverTemp = file.name.startsWith(".") && file.name.endsWith(".tmp")
                val orphan = file.name.endsWith(".jpg") && !file.name.startsWith(".") && file.nameWithoutExtension !in ids
                if (leftoverTemp || orphan) file.delete()
            }
        }
    }

    private fun publish(docs: List<ScanDocument>) {
        _documents.value = docs.sortedByDescending { it.updatedAt }
    }

    companion object {
        const val DOCUMENT_JSON = "document.json"
        const val DOCUMENT_TMP = "document.json.tmp"
        const val DOCUMENT_BAK = "document.json.bak"
        val json = Json { ignoreUnknownKeys = true; encodeDefaults = true; explicitNulls = false }
    }
}
