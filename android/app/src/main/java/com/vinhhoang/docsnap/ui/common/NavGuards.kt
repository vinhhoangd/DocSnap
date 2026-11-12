package com.vinhhoang.docsnap.ui.common

import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner

/**
 * Runs `block` only while this screen (a nav back-stack entry) is the resumed one. A fast double tap
 * on Back would otherwise pop twice, past the library, and leave a blank screen; a double tap on a
 * document would open it twice.
 */
inline fun LifecycleOwner.ifResumed(block: () -> Unit) {
    if (lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)) block()
}
