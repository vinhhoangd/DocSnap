package com.vinhhoang.docsnap.ocr

import com.google.android.gms.tasks.Task
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import com.vinhhoang.docsnap.model.TextLine
import com.vinhhoang.docsnap.processing.PageRenderer
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import java.io.File
import java.text.Normalizer
import java.util.concurrent.Executor
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/** On-device OCR with ML Kit (Latin script, which includes Vietnamese diacritics). */
object TextRecognizer {
    /**
     * Longest side handed to ML Kit. Processed pages are at most 4096 px already; ML Kit wants
     * about 16 px per character, which a 10 pt line on A4 keeps comfortably at this size.
     */
    private const val MAX_DIMENSION = 4096

    /** Lines in reading order with normalized boxes; empty if the page has no text. */
    suspend fun recognize(image: File): List<TextLine> = withContext(Dispatchers.Default) {
        val bitmap = PageRenderer.decodeUpright(image, MAX_DIMENSION)
        val width = bitmap.width.toFloat()
        val height = bitmap.height.toFloat()
        val client = try {
            TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS)
        } catch (e: Throwable) {
            bitmap.recycle()
            throw e
        }
        // process() can throw before any task exists (e.g. a bad bitmap): release both right away.
        val task = try {
            client.process(InputImage.fromBitmap(bitmap, 0))
        } catch (e: Throwable) {
            client.close()
            bitmap.recycle()
            throw e
        }
        val text = try {
            task.await()
        } finally {
            // If the coroutine was cancelled, ML Kit may still be reading the bitmap: release it later.
            if (task.isComplete) {
                client.close()
                bitmap.recycle()
            } else {
                task.addOnCompleteListener(DIRECT) { client.close(); bitmap.recycle() }
            }
        }
        val lines = text.textBlocks.flatMap { it.lines }.mapNotNull { line ->
            val box = line.boundingBox ?: return@mapNotNull null
            // ML Kit may return decomposed diacritics (e + U+0302 + U+0301); keep the composed
            // form so search and copy/paste of Vietnamese text behave.
            val clean = Normalizer.normalize(line.text.trim(), Normalizer.Form.NFC)
            if (clean.isEmpty()) return@mapNotNull null
            val left = (box.left / width).coerceIn(0f, 1f)
            val top = (box.top / height).coerceIn(0f, 1f)
            val right = (box.right / width).coerceIn(0f, 1f)
            val bottom = (box.bottom / height).coerceIn(0f, 1f)
            TextLine(clean, left, top, right - left, bottom - top)
        }
        ReadingOrder.sort(lines)
    }

    private val DIRECT = Executor { it.run() }

    private suspend fun <T> Task<T>.await(): T = suspendCancellableCoroutine { cont ->
        addOnCompleteListener(DIRECT) { task ->
            val error = task.exception
            when {
                task.isCanceled -> cont.cancel()
                error != null -> cont.resumeWithException(error)
                else -> cont.resume(task.result)
            }
        }
    }
}
