package com.vinhhoang.docsnap.ui.common

/** Why the scanner couldn't open, in words the user can act on. */
enum class ScanErrorKind { PlayServicesMissing, PlayServicesUpdate, Downloading, NoSpace, Generic }

object ScanErrors {
    // com.google.android.gms.common.ConnectionResult codes.
    private const val SUCCESS = 0
    private const val SERVICE_MISSING = 1
    private const val SERVICE_VERSION_UPDATE_REQUIRED = 2
    private const val SERVICE_DISABLED = 3
    private const val SERVICE_INVALID = 9
    private const val SERVICE_UPDATING = 18

    // com.google.mlkit.common.MlKitException codes.
    private const val UNAVAILABLE = 14
    private const val NOT_ENOUGH_SPACE = 101
    private const val PLAY_SERVICES_TOO_OLD = 207

    /** Maps GoogleApiAvailability.isGooglePlayServicesAvailable(); null means OK to launch. */
    fun forPlayServicesStatus(status: Int): ScanErrorKind? = when (status) {
        SUCCESS -> null
        SERVICE_MISSING, SERVICE_INVALID -> ScanErrorKind.PlayServicesMissing
        SERVICE_VERSION_UPDATE_REQUIRED, SERVICE_DISABLED -> ScanErrorKind.PlayServicesUpdate
        SERVICE_UPDATING -> ScanErrorKind.Downloading
        else -> ScanErrorKind.PlayServicesMissing
    }

    /** Whether the message should come with an "Update" button that opens Play services in the Play Store. */
    fun offersPlayServicesUpdate(kind: ScanErrorKind): Boolean = kind == ScanErrorKind.PlayServicesUpdate

    /** Maps a failure from getStartScanIntent (MlKitException code, if any, and its message). */
    fun forException(mlKitCode: Int?, message: String?): ScanErrorKind {
        val text = message.orEmpty().lowercase()
        return when {
            mlKitCode == PLAY_SERVICES_TOO_OLD -> ScanErrorKind.PlayServicesUpdate
            mlKitCode == NOT_ENOUGH_SPACE -> ScanErrorKind.NoSpace
            "download" in text || "module" in text -> ScanErrorKind.Downloading
            mlKitCode == UNAVAILABLE -> ScanErrorKind.Downloading
            "update" in text || "too old" in text -> ScanErrorKind.PlayServicesUpdate
            else -> ScanErrorKind.Generic
        }
    }
}
