package com.vinhhoang.docsnap.ui.answer

import com.vinhhoang.docsnap.R
import com.vinhhoang.docsnap.answer.AnswerErrors
import com.vinhhoang.docsnap.answer.AnswerEvent
import com.vinhhoang.docsnap.model.PageAnswer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AnswerUiStateTest {
    private fun run(vararg events: AnswerEvent) =
        events.fold(AnswerUiState.started("claude-opus-5-5")) { state, event -> state.reduce(event) }

    @Test fun streamsThenFinishes() {
        val state = run(
            AnswerEvent.Start("claude-opus-5-5"),
            AnswerEvent.Text("### 1. "),
            AnswerEvent.Text("x = 2"),
            AnswerEvent.Done("end_turn", "claude-sonnet-5-5", 10, 20),
        )
        assertEquals(AnswerPhase.Finished, state.phase)
        assertEquals("### 1. x = 2", state.text)
        // The server reports the model that actually answered (e.g. a fallback).
        assertEquals("claude-sonnet-5-5", state.model)
        assertFalse(state.truncated)
    }

    @Test fun waitsUntilFirstText() {
        val waiting = run(AnswerEvent.Start("claude-opus-5-5"))
        assertEquals(AnswerPhase.Waiting, waiting.phase)
        assertTrue(waiting.isRunning)
        assertEquals(AnswerPhase.Streaming, waiting.reduce(AnswerEvent.Text("a")).phase)
    }

    @Test fun maxTokensIsTruncated() {
        assertTrue(run(AnswerEvent.Text("a"), AnswerEvent.Done("max_tokens", "", 0, 0)).truncated)
    }

    @Test fun blankModelKeepsRequestedOne() {
        assertEquals("claude-opus-5-5", run(AnswerEvent.Start(""), AnswerEvent.Text("a"), AnswerEvent.Done(null, "", 0, 0)).model)
    }

    @Test fun doneWithoutTextIsAnError() {
        val state = run(AnswerEvent.Text("  \n"), AnswerEvent.Done("end_turn", "m", 0, 0))
        assertEquals(AnswerPhase.Failed, state.phase)
        assertEquals(AnswerUiState.EMPTY_ANSWER, state.errorCode)
    }

    @Test fun errorEventFails() {
        val state = run(AnswerEvent.Text("partial"), AnswerEvent.Error(AnswerErrors.RATE_LIMITED, "busy"))
        assertEquals(AnswerPhase.Failed, state.phase)
        assertEquals(AnswerErrors.RATE_LIMITED, state.errorCode)
    }

    @Test fun endedWithoutTerminalEventIsIncomplete() {
        val state = run(AnswerEvent.Text("half")).ended()
        assertEquals(AnswerPhase.Failed, state.phase)
        assertEquals(AnswerErrors.INCOMPLETE, state.errorCode)
        val finished = run(AnswerEvent.Text("a"), AnswerEvent.Done(null, "m", 0, 0))
        assertEquals(finished, finished.ended())
    }

    @Test fun stopKeepsPartialTextOrResets() {
        val partial = run(AnswerEvent.Text("half")).stopped()
        assertEquals(AnswerPhase.Stopped, partial.phase)
        assertEquals("half", partial.text)
        assertEquals(AnswerUiState(), run(AnswerEvent.Start("m")).stopped())
    }

    @Test fun savedAnswerOnlyForCurrentVersion() {
        val saved = PageAnswer("**x = 2**", "claude-haiku-5-5", 0, pageVersion = 3)
        val shown = AnswerUiState.initial(saved, 3)
        assertEquals(AnswerPhase.Finished, shown.phase)
        assertEquals("**x = 2**", shown.text)
        assertEquals("claude-haiku-5-5", shown.model)
        assertEquals(AnswerPhase.Idle, AnswerUiState.initial(saved, 4).phase)
        assertEquals(AnswerPhase.Idle, AnswerUiState.initial(null, 0).phase)
        assertEquals(AnswerPhase.Idle, AnswerUiState.initial(saved, null).phase)
    }

    @Test fun errorMessages() {
        assertEquals(R.string.answer_error_unauthorized, answerErrorMessage(AnswerErrors.UNAUTHORIZED))
        assertEquals(R.string.answer_error_too_large, answerErrorMessage(AnswerErrors.TOO_LARGE))
        assertEquals(R.string.answer_error_too_large, answerErrorMessage(AnswerErrors.IMAGE_TOO_LARGE))
        assertEquals(R.string.answer_error_rate_limited, answerErrorMessage("rate_limited"))
        assertEquals(R.string.answer_error_server, answerErrorMessage(AnswerErrors.SERVER_ERROR))
        assertEquals(R.string.answer_error_network, answerErrorMessage(AnswerErrors.NETWORK))
        assertEquals(R.string.answer_error_interrupted, answerErrorMessage(AnswerErrors.INCOMPLETE))
        assertEquals(R.string.answer_error_not_configured, answerErrorMessage(AnswerErrors.NOT_CONFIGURED))
        assertEquals(R.string.answer_error_refusal, answerErrorMessage("refusal"))
        assertEquals(R.string.answer_error_empty, answerErrorMessage(AnswerUiState.EMPTY_ANSWER))
        assertEquals(R.string.answer_error_generic, answerErrorMessage("something_new"))
        assertEquals(R.string.answer_error_generic, answerErrorMessage(null))
    }
}
