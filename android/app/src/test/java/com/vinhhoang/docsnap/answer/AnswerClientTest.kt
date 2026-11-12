package com.vinhhoang.docsnap.answer

import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import okhttp3.Call
import okhttp3.EventListener
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.SocketPolicy
import okio.Buffer
import okio.buffer
import okio.source
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.net.InetAddress
import java.net.ServerSocket
import java.util.Base64
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

class AnswerClientTest {
    @get:Rule val tmp = TemporaryFolder()

    private val server = MockWebServer()
    private lateinit var image: File
    private val imageBytes = ByteArray(300) { (it * 7).toByte() }
    private val rawEncoder = UploadImageEncoder { file, _ -> file.readBytes() }

    @Before fun setUp() {
        server.start(InetAddress.getByName("127.0.0.1"), 0)
        image = tmp.newFile("page.jpg").apply { writeBytes(imageBytes) }
    }

    @After fun tearDown() {
        runCatching { server.shutdown() }
    }

    private val baseUrl get() = "http://127.0.0.1:${server.port}"

    private fun client(
        token: String = "test-token",
        encoder: UploadImageEncoder = rawEncoder,
        http: OkHttpClient? = null,
        base: String = baseUrl,
    ) = AnswerClient(base, token, encoder, http)

    private fun events(client: AnswerClient = client(), ocr: String? = null, model: String = "claude-opus-5-5"): List<AnswerEvent> =
        runBlocking { withTimeout(15_000) { client.answer(image, ocr, model).toList() } }

    private fun ndjson(vararg lines: String) = lines.joinToString("") { "$it\n" }

    private fun ok(body: String) = MockResponse().setResponseCode(200)
        .setHeader("content-type", "application/x-ndjson; charset=utf-8").setBody(body)

    private val start = """{"type":"start","model":"claude-opus-5-5"}"""
    private fun text(t: String) = JSONObject().put("type", "text").put("text", t).toString()
    private val done = """{"type":"done","stopReason":"end_turn","model":"claude-opus-5-5","inputTokens":1200,"outputTokens":340}"""
    private val doneEvent = AnswerEvent.Done("end_turn", "claude-opus-5-5", 1200, 340)

    // MARK: - Streams

    @Test fun normalStream() {
        server.enqueue(ok(ndjson(start, text("### 1. "), text("**x = 2**"), done)))
        assertEquals(
            listOf(
                AnswerEvent.Start("claude-opus-5-5"),
                AnswerEvent.Text("### 1. "),
                AnswerEvent.Text("**x = 2**"),
                doneEvent,
            ),
            events(),
        )
    }

    @Test fun eventSplitAcrossManyChunks() {
        val body = ndjson(start, text("Hello, world"), done)
        server.enqueue(
            MockResponse().setChunkedBody(body, 3).throttleBody(3, 2, TimeUnit.MILLISECONDS),
        )
        assertEquals(
            listOf(AnswerEvent.Start("claude-opus-5-5"), AnswerEvent.Text("Hello, world"), doneEvent),
            events(),
        )
    }

    @Test fun multiByteUtf8SplitMidCharacter() {
        val vietnamese = "Giải phương trình: x² + √2 ≤ 3, v₁ ∈ ℝ³, ∑ ≠ ∞ 😀"
        val body = Buffer().writeUtf8(ndjson(start, text(vietnamese), done))
        // One byte per chunk: every multi-byte character is split.
        server.enqueue(MockResponse().setChunkedBody(body, 1))
        val result = events()
        assertEquals(AnswerEvent.Text(vietnamese), result[1])
        assertEquals(doneEvent, result.last())
    }

    @Test fun escapedLineSeparatorIsDecoded() {
        // The server writes U+2028 as the escape   (toNDJSONLine), so it never splits a line.
        val line = "{\"type\":\"text\",\"text\":\"a\\u2028b\\u2029c\\u0085d\"}"
        server.enqueue(ok(ndjson(start, line, done)))
        assertEquals(AnswerEvent.Text("a b c\u0085d"), events()[1])
    }

    @Test fun blankLinesAreIgnored() {
        server.enqueue(ok("\n" + start + "\n\n   \n" + text("hi") + "\r\n\n" + done + "\n"))
        assertEquals(listOf(AnswerEvent.Start("claude-opus-5-5"), AnswerEvent.Text("hi"), doneEvent), events())
    }

    @Test fun unknownEventTypeIsIgnored() {
        server.enqueue(ok(ndjson(start, """{"type":"ping"}""", """{"type":"thinking","text":"…"}""", text("ok"), done)))
        assertEquals(listOf(AnswerEvent.Start("claude-opus-5-5"), AnswerEvent.Text("ok"), doneEvent), events())
    }

    @Test fun nonJsonLinesAreIgnored() {
        server.enqueue(ok(ndjson(start, "garbage", "{not json", "[1,2,3]", "42", """{"type":"text"}""", text("ok"), done)))
        assertEquals(listOf(AnswerEvent.Start("claude-opus-5-5"), AnswerEvent.Text("ok"), doneEvent), events())
    }

    @Test fun errorEventEndsTheStream() {
        server.enqueue(
            ok(ndjson(start, text("partial"), """{"type":"error","code":"refusal","message":"Claude declined to answer this page."}""", done)),
        )
        val result = events()
        assertEquals(AnswerEvent.Error("refusal", "Claude declined to answer this page."), result.last())
        assertEquals(3, result.size) // the "done" after the error is never read
    }

    @Test fun doneIsLastAndFinalLineWithoutNewlineIsRead() {
        server.enqueue(ok(start + "\n" + text("x") + "\n" + done))
        assertEquals(doneEvent, events().last())
    }

    @Test fun streamEndingWithoutDoneIsIncomplete() {
        server.enqueue(ok(ndjson(start, text("half an answ"))))
        val result = events()
        assertEquals(AnswerEvent.Text("half an answ"), result[1])
        assertEquals(AnswerErrors.INCOMPLETE, (result.last() as AnswerEvent.Error).code)
    }

    @Test fun connectionDropMidStream() {
        val body = ndjson(start, text("a".repeat(2000)), text("b".repeat(2000)), done)
        server.enqueue(ok(body).setSocketPolicy(SocketPolicy.DISCONNECT_DURING_RESPONSE_BODY))
        val result = events()
        val last = result.last() as AnswerEvent.Error
        assertEquals(AnswerErrors.INTERRUPTED, last.code)
        assertFalse(result.any { it is AnswerEvent.Done })
    }

    @Test fun readTimeoutIsReported() {
        val http = OkHttpClient.Builder().readTimeout(300, TimeUnit.MILLISECONDS).build()
        // Headers arrive, then the body stalls (Claude thinking for longer than the read timeout).
        server.enqueue(ok(ndjson(start, text("slow"), done)).setBodyDelay(2, TimeUnit.SECONDS))
        val last = events(client(http = http)).last() as AnswerEvent.Error
        assertEquals(AnswerErrors.TIMEOUT, last.code)
    }

    @Test fun serverPingsKeepALongThinkAlive() {
        // The server's keep-alive: a silence longer than the read timeout, broken up by ping lines.
        val listener = ServerSocket(0, 1, InetAddress.getByName("127.0.0.1"))
        val serverThread = thread {
            runCatching {
                listener.accept().use { socket ->
                    val input = socket.source().buffer()
                    var length = 0L
                    while (true) {
                        val header = input.readUtf8LineStrict()
                        if (header.isEmpty()) break
                        if (header.startsWith("content-length:", ignoreCase = true)) length = header.substringAfter(':').trim().toLong()
                    }
                    input.skip(length)
                    val out = socket.getOutputStream()
                    fun chunk(line: String) {
                        val bytes = (line + "\n").toByteArray()
                        out.write((Integer.toHexString(bytes.size) + "\r\n").toByteArray())
                        out.write(bytes)
                        out.write("\r\n".toByteArray())
                        out.flush()
                    }
                    out.write("HTTP/1.1 200 OK\r\nContent-Type: application/x-ndjson\r\nTransfer-Encoding: chunked\r\n\r\n".toByteArray())
                    chunk(start)
                    repeat(8) {
                        Thread.sleep(150)
                        chunk("""{"type":"ping"}""")
                    }
                    chunk(text("done thinking"))
                    chunk(done)
                    out.write("0\r\n\r\n".toByteArray())
                    out.flush()
                }
            }
        }
        try {
            // 8 × 150 ms = 1.2 s of thinking, far past the 400 ms read timeout, but no single read waits that long.
            val http = OkHttpClient.Builder().readTimeout(400, TimeUnit.MILLISECONDS).build()
            val result = events(client(http = http, base = "http://127.0.0.1:${listener.localPort}"))
            assertEquals(listOf(AnswerEvent.Start("claude-opus-5-5"), AnswerEvent.Text("done thinking"), doneEvent), result)
        } finally {
            listener.close()
            serverThread.join(2_000)
        }
    }

    @Test fun unreachableServerIsANetworkError() {
        val url = baseUrl
        server.shutdown()
        val last = events(client(base = url)).single() as AnswerEvent.Error
        assertEquals(AnswerErrors.NETWORK, last.code)
    }

    // MARK: - HTTP errors

    private fun httpErrorCode(status: Int, body: String = """{"error":"x","message":"Server says no."}"""): AnswerEvent.Error {
        server.enqueue(MockResponse().setResponseCode(status).setHeader("content-type", "application/json").setBody(body))
        return events().single() as AnswerEvent.Error
    }

    @Test fun http401IsUnauthorized() {
        val error = httpErrorCode(401, """{"error":"unauthorized","message":"Unknown app token."}""")
        assertEquals(AnswerEvent.Error(AnswerErrors.UNAUTHORIZED, "Unknown app token."), error)
    }

    @Test fun http403IsUnauthorized() = assertEquals(AnswerErrors.UNAUTHORIZED, httpErrorCode(403).code)

    @Test fun http413IsTooLarge() = assertEquals(AnswerErrors.TOO_LARGE, httpErrorCode(413, "Request Entity Too Large").code)

    @Test fun http429IsRateLimited() = assertEquals(AnswerErrors.RATE_LIMITED, httpErrorCode(429).code)

    @Test fun http400IsBadRequest() {
        val error = httpErrorCode(400, """{"error":"bad_request","message":"Missing page image."}""")
        assertEquals(AnswerEvent.Error(AnswerErrors.BAD_REQUEST, "Missing page image."), error)
    }

    @Test fun http500WithHtmlBodyIsServerError() {
        val error = httpErrorCode(500, "<html>Internal Server Error</html>")
        assertEquals(AnswerErrors.SERVER_ERROR, error.code)
        assertTrue(error.message.contains("500"))
    }

    @Test fun http503NotConfigured() {
        val error = httpErrorCode(503, """{"error":"not_configured","message":"Server is missing keys."}""")
        assertEquals(AnswerErrors.SERVER_NOT_CONFIGURED, error.code)
    }

    @Test fun http502IsServerError() = assertEquals(AnswerErrors.SERVER_ERROR, httpErrorCode(502, "").code)

    @Test fun otherStatusIsHttpError() = assertEquals(AnswerErrors.HTTP_ERROR, httpErrorCode(404).code)

    // MARK: - Cancellation

    @Test fun collectorCancellationCancelsTheCall() {
        // MockWebServer throttles request bodies too, so a raw socket server sends one line and then stalls.
        val clientClosed = CountDownLatch(1)
        val cancelled = CountDownLatch(1)
        val listener = ServerSocket(0, 1, InetAddress.getByName("127.0.0.1"))
        val serverThread = thread {
            listener.accept().use { socket ->
                val input = socket.source().buffer()
                var length = 0L
                while (true) {
                    val header = input.readUtf8LineStrict()
                    if (header.isEmpty()) break
                    if (header.startsWith("content-length:", ignoreCase = true)) length = header.substringAfter(':').trim().toLong()
                }
                input.skip(length)
                val line = start + "\n"
                socket.getOutputStream().apply {
                    write(
                        ("HTTP/1.1 200 OK\r\nContent-Type: application/x-ndjson\r\nTransfer-Encoding: chunked\r\n\r\n" +
                            Integer.toHexString(line.toByteArray().size) + "\r\n" + line + "\r\n").toByteArray(),
                    )
                    flush()
                }
                // Blocks until the client closes the connection (read returns -1) or 20 s pass.
                socket.soTimeout = 20_000
                if (runCatching { input.exhausted() }.getOrDefault(false)) clientClosed.countDown()
            }
        }
        val http = OkHttpClient.Builder().eventListener(object : EventListener() {
            override fun canceled(call: Call) = cancelled.countDown()
        }).build()
        try {
            val began = System.nanoTime()
            val c = client(http = http, base = "http://127.0.0.1:${listener.localPort}")
            val event = runBlocking { withTimeout(10_000) { c.answer(image, null, "claude-opus-5-5").first() } }
            assertEquals(AnswerEvent.Start("claude-opus-5-5"), event)
            assertTrue("call.cancel() was not called", cancelled.await(5, TimeUnit.SECONDS))
            assertTrue("the connection stayed open", clientClosed.await(5, TimeUnit.SECONDS))
            assertTrue("took too long", (System.nanoTime() - began) / 1_000_000 < 8_000)
        } finally {
            listener.close()
            serverThread.join(1_000)
        }
    }

    // MARK: - Configuration and image

    @Test fun notConfiguredWithoutToken() {
        val result = events(client(token = " "))
        assertEquals(AnswerErrors.NOT_CONFIGURED, (result.single() as AnswerEvent.Error).code)
        assertEquals(0, server.requestCount)
    }

    @Test fun malformedTokenIsNotConfiguredAndNeverReachesOkHttp() {
        // OkHttp throws IllegalArgumentException for these, with the token in the message.
        listOf("secret\nvalue", "secret\r", "tökén", "tab\u0000null", "emoji📄").forEach { bad ->
            val c = client(token = bad)
            assertFalse(bad, c.isConfigured)
            val error = events(c).single() as AnswerEvent.Error
            assertEquals(AnswerErrors.NOT_CONFIGURED, error.code)
            assertFalse("the token must not appear in the message", error.message.contains(bad))
        }
        assertEquals(0, server.requestCount)
        assertTrue(AnswerClient.isUsableToken("abc-DEF_123.~!"))
        assertFalse(AnswerClient.isUsableToken("   "))
    }

    @Test fun notConfiguredWithoutUrl() {
        val c = AnswerClient("", "test-token", rawEncoder)
        assertFalse(c.isConfigured)
        assertEquals(AnswerErrors.NOT_CONFIGURED, (events(c).single() as AnswerEvent.Error).code)
    }

    @Test fun plainHttpIsOnlyAllowedForLoopback() {
        assertFalse(AnswerClient("http://example.com", "t").isConfigured)
        assertTrue(AnswerClient("https://docsnap.example.com", "t").isConfigured)
        assertTrue(AnswerClient("https://docsnap.example.com/", "t").isConfigured)
        assertTrue(client().isConfigured)
    }

    @Test fun unreadableImage() {
        val result = events(client(encoder = { _, _ -> null }))
        assertEquals(AnswerErrors.IMAGE_UNAVAILABLE, (result.single() as AnswerEvent.Error).code)
        assertEquals(0, server.requestCount)
    }

    @Test fun encoderCrashIsAnUnreadableImage() {
        val result = events(client(encoder = { _, _ -> error("boom") }))
        assertEquals(AnswerErrors.IMAGE_UNAVAILABLE, (result.single() as AnswerEvent.Error).code)
    }

    @Test fun imageStillTooLarge() {
        val result = events(client(encoder = { _, _ -> ByteArray(2_600_000) }))
        assertEquals(AnswerErrors.IMAGE_TOO_LARGE, (result.single() as AnswerEvent.Error).code)
        assertEquals(0, server.requestCount)
    }

    // MARK: - Request shape

    @Test fun requestHeadersAndBody() {
        server.enqueue(ok(ndjson(start, done)))
        events(client(token = "secret-123"), ocr = null, model = "claude-sonnet-5-5")
        val request = server.takeRequest(5, TimeUnit.SECONDS)!!
        assertEquals("POST", request.method)
        assertEquals("/api/answer", request.path)
        assertEquals("secret-123", request.getHeader("x-docsnap-token"))
        assertTrue(request.getHeader("Content-Type")!!.startsWith("application/json"))
        val body = JSONObject(request.body.readUtf8())
        assertEquals(Base64.getEncoder().encodeToString(imageBytes), body.getString("image"))
        assertEquals("claude-sonnet-5-5", body.getString("model"))
        assertFalse("text must be omitted when null", body.has("text"))
        assertEquals(setOf("image", "model"), body.keySet())
    }

    @Test fun ocrTextIsSent() {
        server.enqueue(ok(ndjson(start, done)))
        events(ocr = "Câu 1: Tính x² − 4 = 0", model = "claude-haiku-5-5")
        val body = JSONObject(server.takeRequest(5, TimeUnit.SECONDS)!!.body.readUtf8())
        assertEquals("Câu 1: Tính x² − 4 = 0", body.getString("text"))
        assertEquals("claude-haiku-5-5", body.getString("model"))
    }

    @Test fun blankOcrTextIsOmitted() {
        server.enqueue(ok(ndjson(start, done)))
        events(ocr = "  \n ")
        assertFalse(JSONObject(server.takeRequest(5, TimeUnit.SECONDS)!!.body.readUtf8()).has("text"))
    }

    @Test fun trailingSlashInBaseUrl() {
        server.enqueue(ok(ndjson(start, done)))
        events(client(base = "$baseUrl/"))
        assertEquals("/api/answer", server.takeRequest(5, TimeUnit.SECONDS)!!.path)
    }

    // MARK: - Health

    private fun health(c: AnswerClient = client()) = runBlocking { withTimeout(20_000) { c.health() } }

    @Test fun healthTrueWhenConfigured() {
        server.enqueue(MockResponse().setBody("""{"ok":true,"service":"docsnap-answer","configured":true,"defaultModel":"claude-opus-5-5"}"""))
        assertTrue(health())
        val request = server.takeRequest(5, TimeUnit.SECONDS)!!
        assertEquals("GET", request.method)
        assertEquals("/api/answer", request.path)
    }

    @Test fun healthFalseWhenServerNotConfigured() {
        server.enqueue(MockResponse().setBody("""{"ok":true,"configured":false}"""))
        assertFalse(health())
    }

    @Test fun healthFalseOnErrorStatus() {
        server.enqueue(MockResponse().setResponseCode(500).setBody("""{"configured":true}"""))
        assertFalse(health())
    }

    @Test fun healthFalseOnNonJson() {
        server.enqueue(MockResponse().setBody("<html>hi</html>"))
        assertFalse(health())
    }

    @Test fun healthFalseWhenUnreachable() {
        val url = baseUrl
        server.shutdown()
        assertFalse(health(client(base = url)))
    }

    @Test fun healthFalseWhenNotConfigured() {
        assertFalse(health(client(token = "")))
        assertEquals(0, server.requestCount)
    }
}
