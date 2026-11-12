package com.vinhhoang.docsnap.scan

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.IntentSenderRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.platform.LocalContext
import com.google.android.gms.common.GoogleApiAvailability
import com.google.mlkit.common.MlKitException
import com.google.mlkit.vision.documentscanner.GmsDocumentScannerOptions
import com.google.mlkit.vision.documentscanner.GmsDocumentScanning
import com.google.mlkit.vision.documentscanner.GmsDocumentScanningResult
import com.vinhhoang.docsnap.R
import com.vinhhoang.docsnap.ui.common.ScanErrorKind
import com.vinhhoang.docsnap.ui.common.ScanErrors
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.util.UUID

/**
 * Opens Google's ML Kit document scanner (auto edges, auto-capture, border adjusting, gallery import)
 * and returns the scanned pages as JPEG files in the app cache.
 */
class ScannerHandle(val launch: () -> Unit)

/** Pages per scan; the scanner itself stops the user there. */
const val SCAN_PAGE_LIMIT = 50

/**
 * The scanner, ready to launch. `onPages` gets JPEG copies in cache/scans (the caller deletes them
 * once saved). Cancelling calls nothing. `onError` gets a message ready to show. `onImporting` is
 * called with true while the pages are copied out of the scanner (a second or so for many pages).
 */
@Composable
fun rememberScanner(
    onPages: (List<File>) -> Unit,
    onError: (String) -> Unit,
    onImporting: (Boolean) -> Unit = {},
): ScannerHandle {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val currentOnPages by rememberUpdatedState(onPages)
    val currentOnError by rememberUpdatedState(onError)
    val currentOnImporting by rememberUpdatedState(onImporting)

    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.StartIntentSenderForResult()) { result ->
        if (result.resultCode != Activity.RESULT_OK) return@rememberLauncherForActivityResult // cancelled
        val uris = GmsDocumentScanningResult.fromActivityResultIntent(result.data)?.pages.orEmpty().map { it.imageUri }
        if (uris.isEmpty()) return@rememberLauncherForActivityResult
        val app = context.applicationContext
        scope.launch {
            currentOnImporting(true)
            val files = runCatching { withContext(Dispatchers.IO) { copyToCache(app, uris) } }
            currentOnImporting(false)
            files.fold(
                onSuccess = { currentOnPages(it) },
                onFailure = { currentOnError(context.getString(R.string.lib_error_save_scan)) },
            )
        }
    }

    return remember(launcher) {
        ScannerHandle {
            val activity = context.findActivity()
            if (activity == null) {
                currentOnError(context.getString(R.string.lib_scan_error_generic))
                return@ScannerHandle
            }
            val status = GoogleApiAvailability.getInstance().isGooglePlayServicesAvailable(activity)
            ScanErrors.forPlayServicesStatus(status)?.let {
                currentOnError(context.getString(messageFor(it)))
                return@ScannerHandle
            }
            val options = GmsDocumentScannerOptions.Builder()
                .setScannerMode(GmsDocumentScannerOptions.SCANNER_MODE_FULL)
                .setGalleryImportAllowed(true)
                .setPageLimit(SCAN_PAGE_LIMIT)
                .setResultFormats(GmsDocumentScannerOptions.RESULT_FORMAT_JPEG)
                .build()
            GmsDocumentScanning.getClient(options)
                .getStartScanIntent(activity)
                .addOnSuccessListener { sender ->
                    runCatching { launcher.launch(IntentSenderRequest.Builder(sender).build()) }
                        .onFailure { currentOnError(context.getString(R.string.lib_scan_error_generic)) }
                }
                .addOnFailureListener { e ->
                    val kind = ScanErrors.forException((e as? MlKitException)?.errorCode, e.message)
                    currentOnError(context.getString(messageFor(kind)))
                }
        }
    }
}

private fun messageFor(kind: ScanErrorKind): Int = when (kind) {
    ScanErrorKind.PlayServicesMissing -> R.string.lib_scan_error_play_services_missing
    ScanErrorKind.PlayServicesUpdate -> R.string.lib_scan_error_play_services_update
    ScanErrorKind.Downloading -> R.string.lib_scan_error_downloading
    ScanErrorKind.NoSpace -> R.string.lib_scan_error_no_space
    ScanErrorKind.Generic -> R.string.lib_scan_error_generic
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

private tailrec fun Context.findActivity(): Activity? = when (this) {
    is Activity -> this
    is ContextWrapper -> baseContext.findActivity()
    else -> null
}
