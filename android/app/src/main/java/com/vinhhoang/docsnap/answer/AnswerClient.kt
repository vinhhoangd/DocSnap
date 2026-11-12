package com.vinhhoang.docsnap.answer

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put
import okhttp3.Call
import okhttp3.Callback
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import okio.BufferedSource
import java.io.File
import java.io.IOException
import java.io.InterruptedIOException
import java.util.Base64
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import kotlin.coroutines.resume

/** Events streamed back by the DocSnap server (server/api/answer.ts, NDJSON lines). */
sealed interface AnswerEvent {
    data class Start(val model: String) : AnswerEvent
    data class Text(val text: String) : AnswerEvent
    data class Done(val stopReason: String?, val model: String, val inputTokens: Int, val outputTokens: Int) : AnswerEvent
    data class Error(val code: String, val message: String) : AnswerEvent
}

/**
 * Stable error codes produced by [AnswerClient] itself. The server's own `error` events pass their
 * code through unchanged (`refusal`, `rate_limited`, `server_key`, `connection`, `api_error`, …).
 */
object AnswerErrors {
    const val NOT_CONFIGURED = "not_configured"
    const val IMAGE_UNAVAILABLE = "image_unavailable"
    const val IMAGE_TOO_LARGE = "image_too_large"
    const val UNAUTHORIZED = "unauthorized"           // 401 / 403
    const val TOO_LARGE = "too_large"                 // 413
    const val RATE_LIMITED = "rate_limited"           // 429 (same code the server uses)
    const val BAD_REQUEST = "bad_request"             // 400
    const val SERVER_NOT_CONFIGURED = "server_not_configured" // 503 {"error":"not_configured"}
    const val SERVER_ERROR = "server_error"           // 5xx
    const val HTTP_ERROR = "http_error"               // any other non-200
    const val NETWORK = "network"                     // couldn't connect / send
    const val TIMEOUT = "timeout"
    const val INTERRUPTED = "interrupted"             // connection dropped mid-answer
    const val INCOMPLETE = "incomplete"               // stream ended without "done"
}

/**
 * Sends a page image (and optional OCR text) to the DocSnap Answer server and streams Claude's answer.
 * Same contract as the iPhone app's AnswerService: POST {baseUrl}/api/answer with header
 * `x-docsnap-token`, JSON body {image: base64 JPEG (≤ ~2.5 MB), text?, model?}; the reply is NDJSON.
 *
 * The Bitmap work lives behind [UploadImageEncoder], so everything here runs on a plain JVM in tests.
 */
class AnswerClient(
    private val baseUrl: String,
    private val token: String,
    private val encoder: UploadImageEncoder = BitmapUploadEncoder,
    httpClient: OkHttpClient? = null,
) {
    private val answerUrl: HttpUrl? = baseUrl.trim().trimEnd('/').let { "$it/api/answer" }.toHttpUrlOrNull()

    /**
     * True when the app was built with a server address and a usable token (local.properties).
     * The token must be printable ASCII: OkHttp rejects anything else in a header, and its exception
     * message would carry the token into logcat.
     */
    val isConfigured: Boolean
        get() = isUsableToken(token) && answerUrl != null &&
            (answerUrl.isHttps || answerUrl.host in LOOPBACK_HOSTS)

    private val http: OkHttpClient = httpClient ?: OkHttpClient.Builder()
        .connectTimeout(20, TimeUnit.SECONDS)
        .writeTimeout(60, TimeUnit.SECONDS)
        // Claude can think for a while before the first text; this is per read, not for the whole answer.
        .readTimeout(120, TimeUnit.SECONDS)
        .build()

    /**
     * Streams the answer. The flow always ends with exactly one [AnswerEvent.Done] or [AnswerEvent.Error]
     * (unless the collector cancels, which cancels the HTTP call).
     */
    fun answer(image: File, ocrText: String?, model: String): Flow<AnswerEvent> = callbackFlow {
        val url = answerUrl
        if (!isConfigured || url == null) {
            send(AnswerEvent.Error(AnswerErrors.NOT_CONFIGURED, "The app doesn't know the DocSnap server address."))
            close()
            return@callbackFlow
        }
        // The collector can cancel at any moment, including before the call exists: both sides check.
        val callRef = AtomicReference<Call?>(null)
        val cancelled = AtomicBoolean(false)
        launch(Dispatchers.IO) {
            val jpeg = try {
                encoder.encode(image, MAX_IMAGE_BASE64)
            } catch (e: Exception) {
                null
            } catch (e: OutOfMemoryError) {
                null
            }
            when {
                jpeg == null -> send(AnswerEvent.Error(AnswerErrors.IMAGE_UNAVAILABLE, "This page's image couldn't be read."))
                base64Length(jpeg.size) > MAX_IMAGE_BASE64 ->
                    send(AnswerEvent.Error(AnswerErrors.IMAGE_TOO_LARGE, "This page's image is too large to send."))
                else -> {
                    // Never let a bad header value escape: its exception message contains the value.
                    val request = try {
                        buildRequest(url, jpeg, ocrText, model)
                    } catch (e: RuntimeException) {
                        null
                    }
                    if (request == null) {
                        send(AnswerEvent.Error(AnswerErrors.NOT_CONFIGURED, "The app's DocSnap server settings are invalid."))
                    } else {
                        val call = http.newCall(request)
                        callRef.set(call)
                        if (cancelled.get()) call.cancel()
                        stream(call) { send(it) }
                    }
                }
            }
            close()
        }
        awaitClose {
            cancelled.set(true)
            callRef.get()?.cancel()
        }
    }

    /** GET /api/answer — true when the server is reachable and has its keys configured. */
    suspend fun health(): Boolean {
        val url = answerUrl ?: return false
        if (!isConfigured) return false
        val call = http.newBuilder().callTimeout(15, TimeUnit.SECONDS).build()
            .newCall(Request.Builder().url(url).get().build())
        return suspendCancellableCoroutine { cont ->
            cont.invokeOnCancellation { call.cancel() }
            call.enqueue(object : Callback {
                override fun onFailure(call: Call, e: IOException) {
                    if (cont.isActive) cont.resume(false)
                }

                override fun onResponse(call: Call, response: Response) {
                    val ok = response.use {
                        it.code == 200 && runCatching {
                            json.parseToJsonElement(it.body?.string().orEmpty()).jsonObject["configured"]
                                ?.let { v -> (v as? JsonPrimitive)?.booleanOrNull } == true
                        }.getOrDefault(false)
                    }
                    if (cont.isActive) cont.resume(ok)
                }
            })
        }
    }

    // MARK: - Internals

    private fun buildRequest(url: HttpUrl, jpeg: ByteArray, ocrText: String?, model: String): Request {
        val body = buildJsonObject {
            put("image", Base64.getEncoder().encodeToString(jpeg))
            put("model", model)
            if (!ocrText.isNullOrBlank()) put("text", ocrText)
        }
        return Request.Builder()
            .url(url)
            .header("x-docsnap-token", token)
            .header("Accept", "application/x-ndjson")
            .post(body.toString().toRequestBody(JSON_MEDIA))
            .build()
    }

    /** Runs the call and forwards parsed events; always finishes with one terminal event unless cancelled. */
    private suspend fun stream(call: Call, emit: suspend (AnswerEvent) -> Unit) {
        val response = try {
            call.execute()
        } catch (e: IOException) {
            if (!call.isCanceled()) emit(networkError(e, connected = false))
            return
        } catch (e: RuntimeException) { // e.g. a malformed header value; never crash the app
            emit(AnswerEvent.Error(AnswerErrors.NETWORK, "Couldn't reach the DocSnap server."))
            return
        }
        response.use {
            if (it.code != 200) {
                emit(httpError(it.code, it.body?.let { b -> readSnippet(b.source()) }))
                return
            }
            val source = it.body?.source() ?: run {
                emit(AnswerEvent.Error(AnswerErrors.INCOMPLETE, "The server sent an empty reply."))
                return
            }
            try {
                while (true) {
                    // Reads bytes up to '\n' and only then decodes UTF-8, so characters split across
                    // network chunks are reassembled correctly.
                    val line = source.readUtf8Line() ?: break
                    val event = parseLine(line) ?: continue
                    emit(event)
                    if (event is AnswerEvent.Done || event is AnswerEvent.Error) return
                }
            } catch (e: IOException) {
                if (!call.isCanceled()) emit(networkError(e, connected = true))
                return
            }
            if (!call.isCanceled()) {
                emit(AnswerEvent.Error(AnswerErrors.INCOMPLETE, "The answer was interrupted before it finished."))
            }
        }
    }

    companion object {
        /** Server limit on the base64 image (server/api/answer.ts MAX_IMAGE_BASE64). */
        const val MAX_IMAGE_BASE64 = 3_400_000

        private val LOOPBACK_HOSTS = setOf("localhost", "127.0.0.1")
        private val JSON_MEDIA = "application/json; charset=utf-8".toMediaType()
        private val json = Json { ignoreUnknownKeys = true }

        /** A token OkHttp accepts as a header value: non-blank, printable ASCII only. */
        fun isUsableToken(token: String): Boolean =
            token.isNotBlank() && token.all { it in ' '..'~' }

        /** Length of the base64 text for `bytes` bytes (with padding). */
        fun base64Length(bytes: Int): Long = 4L * ((bytes + 2) / 3)

        /** Decodes one NDJSON line; blank, malformed and unknown lines return null and are skipped. */
        fun parseLine(line: String): AnswerEvent? {
            val trimmed = line.trim()
            if (trimmed.isEmpty()) return null
            val obj = runCatching { json.parseToJsonElement(trimmed) as? JsonObject }.getOrNull() ?: return null
            fun str(key: String) = (obj[key] as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull
            fun int(key: String) = (obj[key] as? JsonPrimitive)?.intOrNull ?: 0
            return when (str("type")) {
                "start" -> AnswerEvent.Start(str("model").orEmpty())
                "text" -> str("text")?.let { AnswerEvent.Text(it) }
                "done" -> AnswerEvent.Done(str("stopReason"), str("model").orEmpty(), int("inputTokens"), int("outputTokens"))
                "error" -> AnswerEvent.Error(str("code") ?: "error", str("message") ?: "Something went wrong.")
                // Keep-alive line the server sends every 15 s while Claude thinks; reading it resets the read timeout.
                "ping" -> null
                else -> null
            }
        }

        /** Maps a non-200 reply (with its JSON body like {"error":"…","message":"…"}) to an error event. */
        fun httpError(status: Int, body: String?): AnswerEvent.Error {
            val obj = body?.let { runCatching { json.parseToJsonElement(it) as? JsonObject }.getOrNull() }
            val serverCode = (obj?.get("error") as? JsonPrimitive)?.contentOrNull
            val message = (obj?.get("message") as? JsonPrimitive)?.contentOrNull
                ?: "The DocSnap server returned an error ($status)."
            val code = when {
                status == 401 || status == 403 -> AnswerErrors.UNAUTHORIZED
                status == 413 -> AnswerErrors.TOO_LARGE
                status == 429 -> AnswerErrors.RATE_LIMITED
                status == 400 -> AnswerErrors.BAD_REQUEST
                status == 503 && serverCode == "not_configured" -> AnswerErrors.SERVER_NOT_CONFIGURED
                status in 500..599 -> AnswerErrors.SERVER_ERROR
                else -> AnswerErrors.HTTP_ERROR
            }
            return AnswerEvent.Error(code, message)
        }

        /** The first 16 KB of an error body (enough for the server's JSON message). */
        private fun readSnippet(source: BufferedSource): String? = runCatching {
            source.request(16_384)
            source.buffer.readUtf8(minOf(source.buffer.size, 16_384))
        }.getOrNull()

        private fun networkError(e: IOException, connected: Boolean): AnswerEvent.Error = when {
            // SocketTimeoutException is an InterruptedIOException; so is OkHttp's call timeout.
            e is InterruptedIOException -> AnswerEvent.Error(AnswerErrors.TIMEOUT, "Claude took too long to answer.")
            connected -> AnswerEvent.Error(AnswerErrors.INTERRUPTED, "The connection dropped before the answer finished.")
            else -> AnswerEvent.Error(AnswerErrors.NETWORK, "Couldn't reach the DocSnap server.")
        }
    }
}
