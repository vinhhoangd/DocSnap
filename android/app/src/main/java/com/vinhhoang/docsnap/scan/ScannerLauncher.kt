package com.vinhhoang.docsnap.scan

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.IntentSenderRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.annotation.StringRes
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Stable
import androidx.compose.runtime.State
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.google.android.gms.common.GoogleApiAvailability
import com.google.mlkit.common.MlKitException
import com.google.mlkit.vision.documentscanner.GmsDocumentScannerOptions
import com.google.mlkit.vision.documentscanner.GmsDocumentScanning
import com.vinhhoang.docsnap.R
import com.vinhhoang.docsnap.ui.common.CollectEvents
import com.vinhhoang.docsnap.ui.common.ScanErrorKind
import com.vinhhoang.docsnap.ui.common.ScanErrors

/** Pages per scan; the scanner itself stops the user there. */
const val SCAN_PAGE_LIMIT = 50

/**
 * Why a scan didn't arrive, ready to show. When `offersPlayServicesUpdate` is set the message
 * dialog gets an "Update" button that opens Google Play services in the Play Store.
 */
data class ScanProblem(@StringRes val message: Int, val offersPlayServicesUpdate: Boolean = false)

/**
 * Google's ML Kit document scanner (auto edges, auto-capture, border adjusting, gallery import),
 * ready to launch. `busyMessage` is non-null while the scanner is opening or its pages are being
 * copied; show it as a busy overlay. Taps on `launch` while busy are ignored.
 */
@Stable
class ScannerHandle internal constructor(val launch: () -> Unit, private val busyState: State<Int?>) {
    @get:StringRes
    val busyMessage: Int? get() = busyState.value
}

/**
 * The scanner. `onPages` gets JPEG copies in cache/scans (the caller deletes them once saved).
 * Cancelling calls nothing. The copy runs in a view model, so turning on dark mode or changing the
 * font size mid-copy doesn't lose the scan; results wait until the screen is visible again.
 */
@Composable
fun rememberScanner(onPages: (List<java.io.File>) -> Unit, onError: (ScanProblem) -> Unit): ScannerHandle {
    val context = LocalContext.current
    val vm: ScanImportViewModel = viewModel(key = "scanner")
    val currentOnPages by rememberUpdatedState(onPages)
    val currentOnError by rememberUpdatedState(onError)

    CollectEvents(vm.outcomes) { outcome ->
        when (outcome) {
            is ScanOutcome.Pages -> currentOnPages(outcome.files)
            is ScanOutcome.Failed -> currentOnError(outcome.problem)
        }
    }

    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.StartIntentSenderForResult()) { result ->
        vm.onScannerResult(result.resultCode, result.data)
    }

    val opening by vm.opening.collectAsStateWithLifecycle()
    val importing by vm.importing.collectAsStateWithLifecycle()
    val busy = remember {
        derivedStateOf {
            when {
                importing -> R.string.lib_saving
                opening -> R.string.lib_scan_opening
                else -> null
            }
        }
    }

    return remember(launcher, vm) {
        ScannerHandle(
            launch = launch@{
                if (!vm.beginOpening()) return@launch // already opening or importing: a double tap
                val activity = context.findActivity() ?: return@launch vm.fail(ScanErrorKind.Generic)
                val gms = GoogleApiAvailability.getInstance()
                val status = gms.isGooglePlayServicesAvailable(activity)
                ScanErrors.forPlayServicesStatus(status)?.let { kind ->
                    // Google's own dialog (with an Update / Enable button) where the user can fix it.
                    val shown = kind != ScanErrorKind.Downloading && gms.isUserResolvableError(status) &&
                        runCatching { gms.showErrorDialogFragment(activity, status, PLAY_SERVICES_REQUEST) }.getOrDefault(false)
                    return@launch if (shown) vm.fail(null) else vm.fail(kind)
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
                            .onFailure { vm.fail(ScanErrorKind.Generic) }
                    }
                    .addOnFailureListener { e ->
                        vm.fail(ScanErrors.forException((e as? MlKitException)?.errorCode, e.message))
                    }
            },
            busyState = busy,
        )
    }
}

/** The text for a scanner error. */
@StringRes
internal fun messageFor(kind: ScanErrorKind): Int = when (kind) {
    ScanErrorKind.PlayServicesMissing -> R.string.lib_scan_error_play_services_missing
    ScanErrorKind.PlayServicesUpdate -> R.string.lib_scan_error_play_services_update
    ScanErrorKind.Downloading -> R.string.lib_scan_error_downloading
    ScanErrorKind.NoSpace -> R.string.lib_scan_error_no_space
    ScanErrorKind.Generic -> R.string.lib_scan_error_generic
}

/** Opens Google Play services in the Play Store (the "Update" button). False if nothing could open it. */
fun openPlayServicesInStore(context: Context): Boolean {
    val id = GoogleApiAvailability.GOOGLE_PLAY_SERVICES_PACKAGE
    val intents = listOf(
        Intent(Intent.ACTION_VIEW, Uri.parse("market://details?id=$id")).setPackage("com.android.vending"),
        Intent(Intent.ACTION_VIEW, Uri.parse("https://play.google.com/store/apps/details?id=$id")),
    )
    for (intent in intents) {
        try {
            if (context !is Activity) intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            context.startActivity(intent)
            return true
        } catch (_: ActivityNotFoundException) {
            // Try the next one.
        }
    }
    return false
}

private const val PLAY_SERVICES_REQUEST = 4201

private tailrec fun Context.findActivity(): Activity? = when (this) {
    is Activity -> this
    is ContextWrapper -> baseContext.findActivity()
    else -> null
}
