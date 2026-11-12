package com.vinhhoang.docsnap.ui.document

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first

/**
 * One long job at a time, with what it is doing in `busy` (null when idle).
 *
 * - [tryStart] is for jobs started by a tap (share, copy text): a second tap while busy is ignored.
 * - [awaitStart] is for work that must not be dropped (saving scanned pages): it waits its turn.
 */
class BusyGate<K : Any> {
    private val _busy = MutableStateFlow<K?>(null)
    val busy: StateFlow<K?> = _busy.asStateFlow()

    fun tryStart(kind: K): Boolean = _busy.compareAndSet(null, kind)

    suspend fun awaitStart(kind: K) {
        while (true) {
            _busy.first { it == null }
            if (_busy.compareAndSet(null, kind)) return
        }
    }

    fun finish() {
        _busy.value = null
    }
}
