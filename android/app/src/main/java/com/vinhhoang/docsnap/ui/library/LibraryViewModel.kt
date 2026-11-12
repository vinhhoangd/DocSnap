package com.vinhhoang.docsnap.ui.library

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.vinhhoang.docsnap.DocSnapApp
import com.vinhhoang.docsnap.R
import com.vinhhoang.docsnap.model.ScanDocument
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

sealed interface LibraryEvent {
    data class OpenDocument(val id: String) : LibraryEvent
    data object SaveFailed : LibraryEvent
    data object ChangeFailed : LibraryEvent
}

/**
 * Keeps the "Saving…" state and the save itself alive across configuration changes (dark mode,
 * language, font size), so a scan is never lost or saved twice.
 */
class LibraryViewModel(application: Application) : AndroidViewModel(application) {
    private val app = application as DocSnapApp

    private val _busy = MutableStateFlow(false)
    val busy: StateFlow<Boolean> = _busy.asStateFlow()

    private val _events = Channel<LibraryEvent>(Channel.BUFFERED)
    val events: Flow<LibraryEvent> = _events.receiveAsFlow()

    init {
        // Scans left behind by a crash or process death while saving.
        viewModelScope.launch(Dispatchers.IO) {
            val cutoff = System.currentTimeMillis() - STALE_SCAN_MS
            File(app.cacheDir, "scans").listFiles()?.filter { it.lastModified() < cutoff }?.forEach { it.delete() }
        }
    }

    /** Saves scanned pages as a new document, opens it, then deletes the temporary files. */
    fun saveScan(files: List<File>) {
        if (files.isEmpty()) return
        viewModelScope.launch {
            _busy.value = true
            try {
                val doc = withContext(NonCancellable) {
                    app.store.createDocument(
                        files,
                        app.settings.defaultFilter.value,
                        title = ScanDocument.defaultTitle(prefix = app.getString(R.string.default_title_prefix)),
                    )
                }
                _events.send(LibraryEvent.OpenDocument(doc.id))
            } catch (e: CancellationException) {
                throw e
            } catch (_: Throwable) {
                _events.trySend(LibraryEvent.SaveFailed)
            } finally {
                withContext(NonCancellable + Dispatchers.IO) { files.forEach { it.delete() } }
                _busy.value = false
            }
        }
    }

    fun rename(id: String, title: String) = runChange { app.store.rename(id, title) }

    fun delete(id: String) = runChange { app.store.delete(id) }

    /** Store changes finish even if the user leaves the screen. */
    private fun runChange(block: suspend () -> Unit) {
        app.appScope.launch {
            try {
                block()
            } catch (e: CancellationException) {
                throw e
            } catch (_: Throwable) {
                _events.trySend(LibraryEvent.ChangeFailed)
            }
        }
    }

    private companion object {
        const val STALE_SCAN_MS = 60 * 60 * 1000L
    }
}
