package com.vinhhoang.docsnap.ui.answer

import androidx.annotation.StringRes
import com.vinhhoang.docsnap.R
import com.vinhhoang.docsnap.answer.AnswerErrors
import com.vinhhoang.docsnap.answer.AnswerEvent
import com.vinhhoang.docsnap.model.PageAnswer

enum class AnswerPhase { Idle, Waiting, Streaming, Finished, Stopped, Failed }

/** What the Answer sheet shows. Pure, so the event handling is JVM-testable. */
data class AnswerUiState(
    val phase: AnswerPhase = AnswerPhase.Idle,
    val text: String = "",
    /** Model id: the one requested, then the one the server reports. */
    val model: String = "",
    /** Claude hit the length limit. */
    val truncated: Boolean = false,
    val errorCode: String? = null,
) {
    fun reduce(event: AnswerEvent): AnswerUiState = when (event) {
        is AnswerEvent.Start -> copy(model = event.model.ifBlank { model })
        is AnswerEvent.Text -> copy(phase = AnswerPhase.Streaming, text = text + event.text)
        is AnswerEvent.Done ->
            if (text.isBlank()) {
                copy(phase = AnswerPhase.Failed, errorCode = EMPTY_ANSWER)
            } else {
                copy(phase = AnswerPhase.Finished, model = event.model.ifBlank { model }, truncated = event.stopReason == "max_tokens")
            }
        is AnswerEvent.Error -> copy(phase = AnswerPhase.Failed, errorCode = event.code)
    }

    /** The flow finished; if no Done/Error arrived the answer is incomplete. */
    fun ended(): AnswerUiState =
        if (phase == AnswerPhase.Waiting || phase == AnswerPhase.Streaming) {
            copy(phase = AnswerPhase.Failed, errorCode = AnswerErrors.INCOMPLETE)
        } else {
            this
        }

    /** The Stop button: keep what arrived so far (not saved), or go back to the start if nothing did. */
    fun stopped(): AnswerUiState = when {
        phase != AnswerPhase.Waiting && phase != AnswerPhase.Streaming -> this
        text.isBlank() -> AnswerUiState()
        else -> copy(phase = AnswerPhase.Stopped)
    }

    val isRunning: Boolean get() = phase == AnswerPhase.Waiting || phase == AnswerPhase.Streaming

    companion object {
        const val EMPTY_ANSWER = "empty_answer"

        fun started(model: String) = AnswerUiState(phase = AnswerPhase.Waiting, model = model)

        /** A saved answer is shown only if it was made from the page's current image. */
        fun initial(saved: PageAnswer?, pageVersion: Int?): AnswerUiState =
            if (saved != null && saved.pageVersion == pageVersion && saved.text.isNotBlank()) {
                AnswerUiState(phase = AnswerPhase.Finished, text = saved.text, model = saved.model)
            } else {
                AnswerUiState()
            }
    }
}

/** Friendly, translated message for an error code from AnswerClient, the server, or the sheet. */
@StringRes
fun answerErrorMessage(code: String?): Int = when (code) {
    AnswerErrors.NOT_CONFIGURED -> R.string.answer_error_not_configured
    AnswerErrors.SERVER_NOT_CONFIGURED, "server_key" -> R.string.answer_error_server_setup
    AnswerErrors.IMAGE_UNAVAILABLE -> R.string.answer_error_image_unavailable
    AnswerErrors.IMAGE_TOO_LARGE, AnswerErrors.TOO_LARGE -> R.string.answer_error_too_large
    AnswerErrors.UNAUTHORIZED -> R.string.answer_error_unauthorized
    AnswerErrors.RATE_LIMITED -> R.string.answer_error_rate_limited
    AnswerErrors.NETWORK -> R.string.answer_error_network
    AnswerErrors.TIMEOUT -> R.string.answer_error_timeout
    AnswerErrors.INTERRUPTED, AnswerErrors.INCOMPLETE -> R.string.answer_error_interrupted
    AnswerErrors.BAD_REQUEST -> R.string.answer_error_bad_request
    AnswerErrors.SERVER_ERROR, AnswerErrors.HTTP_ERROR, "api_error", "connection" -> R.string.answer_error_server
    "refusal" -> R.string.answer_error_refusal
    AnswerUiState.EMPTY_ANSWER -> R.string.answer_error_empty
    else -> R.string.answer_error_generic
}
