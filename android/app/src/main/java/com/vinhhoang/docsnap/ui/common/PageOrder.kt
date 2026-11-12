package com.vinhhoang.docsnap.ui.common

/** Index math for "Move left / Move right" on a page (same semantics as DocumentStore.movePage). */
object PageOrder {
    /** Where the page at `from` goes when moved by `step` (-1 left, +1 right); null if it can't move. */
    fun target(from: Int, step: Int, count: Int): Int? {
        if (from !in 0 until count) return null
        val to = from + step
        return to.takeIf { it in 0 until count && it != from }
    }

    fun canMoveLeft(index: Int, count: Int) = target(index, -1, count) != null
    fun canMoveRight(index: Int, count: Int) = target(index, +1, count) != null

    /** The list after moving the item at `from` to `to` (clamped), mirroring the store. */
    fun <T> moved(list: List<T>, from: Int, to: Int): List<T> {
        if (from !in list.indices) return list
        val result = list.toMutableList()
        val item = result.removeAt(from)
        result.add(to.coerceIn(0, result.size), item)
        return result
    }
}
