package com.vinhhoang.docsnap.ui.common

import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.delay

/**
 * Calls `onGone` once when the thing this screen shows (a document) disappears, e.g. it was deleted.
 *
 * - Waits until this screen is the resumed one, so two stacked screens never both pop the back stack.
 * - If the item was never seen (the store is still loading after process death), waits `graceMs`
 *   before giving up, so a restored screen isn't closed by mistake.
 */
@Composable
fun LeaveWhenGone(present: Boolean, onGone: () -> Unit, graceMs: Long = 3000) {
    var seen by rememberSaveable { mutableStateOf(false) }
    var left by remember { mutableStateOf(false) }
    val currentOnGone by rememberUpdatedState(onGone)
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    LaunchedEffect(present) {
        if (present) {
            seen = true
            return@LaunchedEffect
        }
        if (!seen) delay(graceMs)
        lifecycle.repeatOnLifecycle(Lifecycle.State.RESUMED) {
            if (!left) {
                left = true
                currentOnGone()
            }
        }
    }
}
