package com.vinhhoang.docsnap.ui.common

import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle

/**
 * Calls `onGone` once when the thing this screen shows (a document) disappears, e.g. it was deleted.
 *
 * - Waits until this screen is the resumed one, so two stacked screens never both pop the back stack.
 * - Does nothing until the store has `loaded` (after process death a restored screen appears
 *   before the documents are read), so it is never closed by mistake.
 */
@Composable
fun LeaveWhenGone(present: Boolean, loaded: Boolean, onGone: () -> Unit) {
    var left by remember { mutableStateOf(false) }
    val currentOnGone by rememberUpdatedState(onGone)
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    LaunchedEffect(present, loaded) {
        if (present || !loaded) return@LaunchedEffect
        lifecycle.repeatOnLifecycle(Lifecycle.State.RESUMED) {
            if (!left) {
                left = true
                currentOnGone()
            }
        }
    }
}
