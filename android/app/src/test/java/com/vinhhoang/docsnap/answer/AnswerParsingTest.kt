package com.vinhhoang.docsnap.answer

import com.vinhhoang.docsnap.data.AnswerModel
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** Pure helpers of the Answer client: line parsing, HTTP error mapping, upload sizing, model names. */
class AnswerParsingTest {
    @Test fun parsesEveryEventType() {
        assertEquals(AnswerEvent.Start("claude-opus-5-5"), AnswerClient.parseLine("""{"type":"start","model":"claude-opus-5-5"}"""))
        assertEquals(AnswerEvent.Text("x²"), AnswerClient.parseLine("""{"type":"text","text":"x²"}"""))
        assertEquals(
            AnswerEvent.Done(null, "m", 0, 0),
            AnswerClient.parseLine("""{"type":"done","stopReason":null,"model":"m"}"""),
        )
        assertEquals(
            AnswerEvent.Error("error", "Something went wrong."),
            AnswerClient.parseLine("""{"type":"error"}"""),
        )
    }

    @Test fun skipsJunk() {
        listOf("", "   ", "null", "\"text\"", "[]", "{}", """{"type":5}""", """{"type":"text","text":5}""", "{\"type\":")
            .forEach { assertNull(it, AnswerClient.parseLine(it)) }
    }

    @Test fun extraFieldsAreIgnored() {
        assertEquals(AnswerEvent.Text("a"), AnswerClient.parseLine("""{"type":"text","text":"a","index":3,"extra":{"x":1}}"""))
    }

    @Test fun httpErrorWithoutBody() {
        val error = AnswerClient.httpError(429, null)
        assertEquals(AnswerErrors.RATE_LIMITED, error.code)
        assertEquals("The DocSnap server returned an error (429).", error.message)
    }

    @Test fun base64Length() {
        assertEquals(0L, AnswerClient.base64Length(0))
        assertEquals(4L, AnswerClient.base64Length(1))
        assertEquals(4L, AnswerClient.base64Length(3))
        assertEquals(8L, AnswerClient.base64Length(4))
        // The largest JPEG the server takes: 2,550,000 bytes → exactly 3,400,000 chars.
        assertEquals(3_400_000L, AnswerClient.base64Length(2_550_000))
    }

    @Test fun sizingUsesTheFirstStepThatFits() {
        val tried = mutableListOf<Pair<Int, Int>>()
        val bytes = UploadSizing.fit(400) { side, quality ->
            tried += side to quality
            ByteArray(if (side >= 1600) 1_000 else 250)
        }
        assertEquals(250, bytes!!.size)
        assertEquals(listOf(2048 to 85, 2048 to 75, 1600 to 75, 1280 to 70), tried)
    }

    @Test fun sizingPrefers2048AtQuality85() {
        val tried = mutableListOf<Pair<Int, Int>>()
        UploadSizing.fit(AnswerClient.MAX_IMAGE_BASE64) { side, quality -> tried += side to quality; ByteArray(10) }
        assertEquals(listOf(2048 to 85), tried)
    }

    @Test fun sizingReturnsLastTryWhenNothingFits() {
        val bytes = UploadSizing.fit(10) { side, _ -> ByteArray(side) }
        assertEquals(1024, bytes!!.size)
    }

    @Test fun sizingStopsWhenImageUnreadable() {
        assertNull(UploadSizing.fit(10) { _, _ -> null })
    }

    @Test fun sampleSize() {
        assertEquals(1, UploadSizing.sampleSize(2048, 2048))
        assertEquals(1, UploadSizing.sampleSize(4000, 2048))
        assertEquals(2, UploadSizing.sampleSize(4096, 2048))
        assertEquals(4, UploadSizing.sampleSize(9000, 2048))
        assertEquals(1, UploadSizing.sampleSize(500, 2048))
    }

    @Test fun modelNames() {
        assertEquals("Claude Opus 5.5", answerModelName("claude-opus-5-5"))
        assertEquals("Claude Sonnet 5.5", answerModelName("claude-sonnet-5-5-20261101"))
        assertEquals("Claude Haiku 5.5", AnswerModel.Haiku.displayName)
        assertEquals("claude-next", answerModelName("claude-next"))
        assertEquals("Claude", answerModelName(""))
    }
}
