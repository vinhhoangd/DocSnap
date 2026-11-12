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

/**
 * All documents, stored as files (no database yet — auth and sync come later):
 *
 *     <root>/<documentId>/document.json
 *     <root>/<documentId>/original/<pageId>.jpg    the scanner's page, never modified
 *     <root>/<documentId>/processed/<pageId>.jpg   rotation + filter applied, what is shown and shared
 *
 * Writes are serialized with a mutex; `document.json` is written atomically (temp file + rename).
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

    /** Reads every document from disk. Unreadable folders are skipped, not deleted. */
    suspend fun load() = withContext(io) {
        mutex.withLock {
            root.mkdirs()
            val docs = root.listFiles { f -> f.isDirectory }.orEmpty().mapNotNull { dir ->
                runCatching { json.decodeFromString<ScanDocument>(File(dir, DOCUMENT_JSON).readText()) }.getOrNull()
                    ?.takeIf { it.id == dir.name }
            }
            publish(docs)
            _loaded.value = true
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

    private fun write(doc: ScanDocument) {
        val dir = folder(doc.id).apply { mkdirs() }
        val temp = File(dir, "$DOCUMENT_JSON.tmp")
        temp.writeText(json.encodeToString(ScanDocument.serializer(), doc))
        if (!temp.renameTo(File(dir, DOCUMENT_JSON))) {
            File(dir, DOCUMENT_JSON).delete()
            check(temp.renameTo(File(dir, DOCUMENT_JSON))) { "Couldn't save ${doc.id}" }
        }
    }

    private fun publish(docs: List<ScanDocument>) {
        _documents.value = docs.sortedByDescending { it.updatedAt }
    }

    companion object {
        const val DOCUMENT_JSON = "document.json"
        val json = Json { ignoreUnknownKeys = true; encodeDefaults = true; explicitNulls = false }
    }
}
