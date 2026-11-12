package com.vinhhoang.docsnap.ocr

import com.vinhhoang.docsnap.model.TextLine
import java.io.File

/** On-device OCR with ML Kit (Latin script, which includes Vietnamese diacritics). */
object TextRecognizer {
    /** Lines in reading order with normalized boxes; empty if the page has no text. */
    suspend fun recognize(image: File): List<TextLine> {
        TODO("processing agent")
    }
}
