package com.vinhhoang.docsnap.answer

import com.vinhhoang.docsnap.data.AnswerModel

/** Product names are not translated. */
val AnswerModel.displayName: String
    get() = when (this) {
        AnswerModel.Opus -> "Claude Opus 5.5"
        AnswerModel.Sonnet -> "Claude Sonnet 5.5"
        AnswerModel.Haiku -> "Claude Haiku 5.5"
    }

/** Display name for a model id the server reported; unknown ids (e.g. a fallback model) are shown as-is. */
fun answerModelName(id: String): String =
    AnswerModel.entries.firstOrNull { id == it.id || id.startsWith(it.id + "-") }?.displayName ?: id.ifBlank { "Claude" }
