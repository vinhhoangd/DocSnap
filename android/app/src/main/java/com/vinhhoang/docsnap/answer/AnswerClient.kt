package com.vinhhoang.docsnap.answer

import kotlinx.coroutines.flow.Flow
import java.io.File

/** Events streamed back by the DocSnap server (server/api/answer.ts, NDJSON lines). */
sealed interface AnswerEvent {
    data class Start(val model: String) : AnswerEvent
    data class Text(val text: String) : AnswerEvent
    data class Done(val stopReason: String?, val model: String, val inputTokens: Int, val outputTokens: Int) : AnswerEvent
    data class Error(val code: String, val message: String) : AnswerEvent
}

/**
 * Sends a page image (and optional OCR text) to the DocSnap Answer server and streams Claude's answer.
 * Same contract as the iPhone app's AnswerService: POST {baseUrl}/api/answer with header
 * `x-docsnap-token`, JSON body {image: base64 JPEG (≤ ~2.5 MB), text?, model?}.
 */
class AnswerClient(private val baseUrl: String, private val token: String) {
    val isConfigured: Boolean get() = baseUrl.startsWith("https://") && token.isNotBlank()

    fun answer(image: File, ocrText: String?, model: String): Flow<AnswerEvent> {
        TODO("answer agent")
    }
}
