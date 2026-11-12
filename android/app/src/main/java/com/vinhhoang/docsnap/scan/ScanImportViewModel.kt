package com.vinhhoang.docsnap.scan

import android.app.Activity
import android.app.Application
import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.google.mlkit.vision.documentscanner.GmsDocumentScanningResult
import com.vinhhoang.docsnap.R
import com.vinhhoang.docsnap.ui.common.ScanErrorKind
import com.vinhhoang.docsnap.ui.common.ScanErrors
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.util.UUID

sealed interface ScanOutcome {
    data class Pages(val files: List<File>) : ScanOutcome
    data class Failed(val problem: ScanProblem) : ScanOutcome
}

/**
 * Whether the scanner is opening (from the tap until its result comes back) or its pages are being
 * copied. Only one scan at a time: a second tap while either is true is ignored.
 */
class ScanFlight {
    private val _opening = MutableStateFlow(false)
    val opening: StateFlow<Boolean> = _opening.asStateFlow()
    private val _importing = MutableStateFlow(false)
    val importing: StateFlow<Boolean> = _importing.asStateFlow()

    /** True if the scanner may open now (and marks it opening); false while a scan is in flight. */
    fun begin(): Boolean = !_importing.value && _opening.compareAndSet(expect = false, update = true)

    /** The scanner failed to open, or closed (with or without pages). */
    fun end() {
        _opening.value = false
    }

    fun setImporting(value: Boolean) {
        _importing.value = value
    }
}

/**
 * Owns the scanner's in-flight state and copies its pages out of the scanner's temporary URIs.
 * Being a view model, the copy survives configuration changes (dark mode, font size, language),
 * and its result waits in `outcomes` until the screen collects it.
 */
class ScanImportViewModel(application: Application) : AndroidViewModel(application) {
    private val flight = ScanFlight()
    val opening: StateFlow<Boolean> get() = flight.opening
    val importing: StateFlow<Boolean> get() = flight.importing

    private val _outcomes = Channel<ScanOutcome>(Channel.BUFFERED)
    val outcomes: Flow<ScanOutcome> = _outcomes.receiveAsFlow()

    fun beginOpening(): Boolean = flight.begin()

    /** The scanner couldn't open. `kind` null means a system dialog already told the user. */
    fun fail(kind: ScanErrorKind?) {
        flight.end()
        kind?.let { _outcomes.trySend(ScanOutcome.Failed(problemFor(it))) }
    }

    fun onScannerResult(resultCode: Int, data: Intent?) {
        flight.end()
        if (resultCode != Activity.RESULT_OK) return // cancelled
        val uris = GmsDocumentScanningResult.fromActivityResultIntent(data)?.pages.orEmpty().map { it.imageUri }
        if (uris.isEmpty()) return
        import(uris)
    }

    private fun import(uris: List<Uri>) {
        val app = getApplication<Application>()
        flight.setImporting(true)
        viewModelScope.launch {
            try {
                val files = withContext(Dispatchers.IO) { copyToCache(app, uris) }
                _outcomes.send(ScanOutcome.Pages(files))
            } catch (e: CancellationException) {
                throw e
            } catch (_: Throwable) {
                _outcomes.send(ScanOutcome.Failed(ScanProblem(R.string.lib_error_save_scan)))
            } finally {
                flight.setImporting(false)
            }
        }
    }

    private fun problemFor(kind: ScanErrorKind) =
        ScanProblem(messageFor(kind), offersPlayServicesUpdate = ScanErrors.offersPlayServicesUpdate(kind))
}

/** Copies the scanner's page images (content URIs that expire) to cache/scans/<uuid>.jpg. */
private fun copyToCache(context: Context, uris: List<Uri>): List<File> {
    val dir = File(context.cacheDir, "scans").apply { mkdirs() }
    val copied = mutableListOf<File>()
    try {
        for (uri in uris) {
            val target = File(dir, "${UUID.randomUUID()}.jpg")
            copied += target
            val input = context.contentResolver.openInputStream(uri) ?: error("Can't open $uri")
            input.use { src -> target.outputStream().use { dst -> src.copyTo(dst) } }
        }
    } catch (e: Throwable) {
        copied.forEach { it.delete() }
        throw e
    }
    return copied
}
