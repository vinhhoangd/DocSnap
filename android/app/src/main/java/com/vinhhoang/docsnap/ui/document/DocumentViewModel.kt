package com.vinhhoang.docsnap.ui.document

import android.app.Application
import androidx.annotation.StringRes
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.vinhhoang.docsnap.DocSnapApp
import com.vinhhoang.docsnap.R
import com.vinhhoang.docsnap.export.PdfExporter
import com.vinhhoang.docsnap.model.ScanFilter
import com.vinhhoang.docsnap.ocr.TextRecognizer
import com.vinhhoang.docsnap.ui.share.Sharing
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

sealed interface DocumentEvent {
    data class Share(val files: List<File>, val mime: String, val subject: String) : DocumentEvent
    data class CopyText(val label: String, val text: String) : DocumentEvent
    data class Message(@StringRes val text: Int) : DocumentEvent
}

/** What the busy overlay says; null when idle. */
enum class DocumentBusy(@StringRes val message: Int) {
    Saving(R.string.lib_saving),
    MakingPdf(R.string.lib_making_pdf),
    PreparingImages(R.string.lib_preparing_images),
    ReadingText(R.string.lib_reading_text),
}

/**
 * Long document jobs (saving added pages, making a PDF, reading all text). They survive configuration
 * changes; the screen only turns their results into share sheets and messages.
 */
class DocumentViewModel(application: Application) : AndroidViewModel(application) {
    private val app = application as DocSnapApp
    private val store get() = app.store

    private val _busy = MutableStateFlow<DocumentBusy?>(null)
    val busy: StateFlow<DocumentBusy?> = _busy.asStateFlow()

    private val _events = Channel<DocumentEvent>(Channel.BUFFERED)
    val events: Flow<DocumentEvent> = _events.receiveAsFlow()

    fun addPages(documentId: String, files: List<File>) = job(DocumentBusy.Saving, R.string.lib_error_save_scan, cleanup = files) {
        withContext(NonCancellable) { store.addPages(documentId, files, app.settings.defaultFilter.value) }
    }

    fun sharePdf(documentId: String) = job(DocumentBusy.MakingPdf, R.string.lib_share_error) {
        val doc = store.document(documentId) ?: return@job
        val folder = Sharing.newExportFolder(app)
        val pdf = withContext(Dispatchers.IO) { PdfExporter.export(doc, store, folder, app.settings.pdfPageSize.value) }
        _events.send(DocumentEvent.Share(listOf(pdf), Sharing.MIME_PDF, doc.title))
    }

    fun shareImages(documentId: String) = job(DocumentBusy.PreparingImages, R.string.lib_share_error) {
        val doc = store.document(documentId) ?: return@job
        val files = Sharing.prepareImages(app, doc, store)
        _events.send(DocumentEvent.Share(files, Sharing.MIME_JPEG, doc.title))
    }

    /** Reads any page that hasn't been read yet, then copies every page's text in order. */
    fun copyAllText(documentId: String) = job(DocumentBusy.ReadingText, R.string.lib_text_error) {
        val doc = store.document(documentId) ?: return@job
        val texts = doc.pages.map { page ->
            page.recognizedText ?: run {
                val lines = withContext(Dispatchers.IO) { TextRecognizer.recognize(store.processedFile(documentId, page.id)) }
                withContext(NonCancellable) { store.setText(documentId, page.id, page.version, lines) }
                lines.joinToString("\n") { it.text }
            }
        }
        val text = texts.filter { it.isNotBlank() }.joinToString("\n\n")
        if (text.isBlank()) {
            _events.send(DocumentEvent.Message(R.string.lib_doc_no_text))
        } else {
            _events.send(DocumentEvent.CopyText(doc.title, text))
        }
    }

    fun rename(documentId: String, title: String) = change { store.rename(documentId, title) }
    fun delete(documentId: String) = change { store.delete(documentId) }
    fun movePage(documentId: String, from: Int, to: Int) = change { store.movePage(documentId, from, to) }
    fun deletePage(documentId: String, pageId: String) = change { store.deletePage(documentId, pageId) }
    fun rotatePage(documentId: String, pageId: String) = change {
        store.editPage(documentId, pageId) { it.copy(rotation = it.rotation + 1) }
    }
    fun setFilter(documentId: String, pageId: String, filter: ScanFilter) = change {
        store.editPage(documentId, pageId) { it.copy(filter = filter) }
    }

    /** A job with the busy overlay. Only one runs at a time; a second tap while busy is ignored. */
    private fun job(kind: DocumentBusy, @StringRes failure: Int, cleanup: List<File> = emptyList(), block: suspend () -> Unit) {
        if (_busy.value != null) {
            cleanup.forEach { it.delete() }
            return
        }
        _busy.value = kind
        viewModelScope.launch {
            try {
                block()
            } catch (e: CancellationException) {
                throw e
            } catch (_: Throwable) {
                _events.trySend(DocumentEvent.Message(failure))
            } finally {
                if (cleanup.isNotEmpty()) withContext(NonCancellable + Dispatchers.IO) { cleanup.forEach { it.delete() } }
                _busy.value = null
            }
        }
    }

    /** Quick store changes; they finish even if the user leaves the screen. */
    private fun change(block: suspend () -> Unit) {
        app.appScope.launch {
            try {
                block()
            } catch (e: CancellationException) {
                throw e
            } catch (_: Throwable) {
                _events.trySend(DocumentEvent.Message(R.string.error_generic))
            }
        }
    }
}
