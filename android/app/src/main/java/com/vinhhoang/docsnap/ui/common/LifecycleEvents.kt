package com.vinhhoang.docsnap.ui.common

import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberUpdatedState
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.withContext

/**
 * Collects one-off view-model events only while the screen is at least `minState`. Events sent
 * while it isn't (e.g. a PDF finished while the phone was locked) wait in the view model's channel
 * and are handled when the user comes back, instead of starting a share sheet nobody can see.
 *
 * Use STARTED for share sheets and messages, RESUMED for navigation.
 */
@Composable
fun <T> CollectEvents(events: Flow<T>, minState: Lifecycle.State = Lifecycle.State.STARTED, onEvent: (T) -> Unit) {
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    val currentOnEvent by rememberUpdatedState(onEvent)
    LaunchedEffect(events, lifecycle, minState) {
        lifecycle.repeatOnLifecycle(minState) {
            // Main.immediate: an event taken from the channel is handled in the same frame, so it
            // can't be lost between being received and the lifecycle stopping.
            withContext(Dispatchers.Main.immediate) {
                events.collect { currentOnEvent(it) }
            }
        }
    }
}
