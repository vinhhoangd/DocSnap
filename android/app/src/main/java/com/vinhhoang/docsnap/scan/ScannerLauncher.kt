package com.vinhhoang.docsnap.scan

import androidx.compose.runtime.Composable
import java.io.File

/**
 * Opens Google's ML Kit document scanner (auto edges, auto-capture, border adjusting, gallery import)
 * and returns the scanned pages as JPEG files in the app cache.
 */
class ScannerHandle(val launch: () -> Unit)

@Composable
fun rememberScanner(onPages: (List<File>) -> Unit, onError: (String) -> Unit): ScannerHandle {
    TODO("library agent")
}
