package com.vinhhoang.docsnap.model

import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.UUID

/**
 * Same document model as the iPhone app (DocSnap/Models/ScanDocument.swift), so documents can be
 * synced between the two later. Dates are epoch milliseconds.
 */

/** Look applied to a page. Unknown values (from a newer app version) fall back to Magic Color. */
@Serializable(with = ScanFilterSerializer::class)
enum class ScanFilter(val raw: String) {
    Original("original"),
    MagicColor("magicColor"),
    Grayscale("grayscale"),
    BlackWhite("blackWhite"),
    Lighten("lighten");

    companion object {
        fun fromRaw(raw: String?): ScanFilter = entries.firstOrNull { it.raw == raw } ?: MagicColor
    }
}

object ScanFilterSerializer : KSerializer<ScanFilter> {
    override val descriptor = PrimitiveSerialDescriptor("ScanFilter", PrimitiveKind.STRING)
    override fun serialize(encoder: Encoder, value: ScanFilter) = encoder.encodeString(value.raw)
    override fun deserialize(decoder: Decoder): ScanFilter = ScanFilter.fromRaw(decoder.decodeString())
}

/** One line of OCR output; the box is normalized (0..1, top-left origin) within the page image. */
@Serializable
data class TextLine(
    val text: String,
    val left: Float = 0f,
    val top: Float = 0f,
    val width: Float = 0f,
    val height: Float = 0f,
)

/** Claude's answer to the questions on a page, kept until the page image changes. */
@Serializable
data class PageAnswer(
    val text: String,
    val model: String,
    val createdAt: Long,
    /** The page version the answer was made from. */
    val pageVersion: Int,
)

@Serializable
data class ScanPage(
    val id: String = UUID.randomUUID().toString(),
    val filter: ScanFilter = ScanFilter.MagicColor,
    /** Clockwise quarter turns, 0..3. */
    val rotation: Int = 0,
    /** OCR result for the processed image; null until recognized, cleared whenever the image changes. */
    val textLines: List<TextLine>? = null,
    /** Bumped on every edit so cached images are invalidated. */
    val version: Int = 0,
    /** Claude's answer for the current image; cleared whenever the image changes. */
    val answer: PageAnswer? = null,
) {
    val recognizedText: String? get() = textLines?.joinToString("\n") { it.text }

    /** A copy for a changed image: new version, stale OCR and answer dropped. */
    fun edited(filter: ScanFilter = this.filter, rotation: Int = this.rotation): ScanPage =
        copy(filter = filter, rotation = ((rotation % 4) + 4) % 4, version = version + 1, textLines = null, answer = null)
}

@Serializable
data class ScanDocument(
    val id: String = UUID.randomUUID().toString(),
    val title: String,
    val createdAt: Long = System.currentTimeMillis(),
    val updatedAt: Long = createdAt,
    val pages: List<ScanPage> = emptyList(),
) {
    /** All OCR text in page order, for search and "copy all text". */
    val allText: String get() = pages.mapNotNull { it.recognizedText }.joinToString("\n\n")

    companion object {
        /** Default name in the style "Scan 2026-11-12 14.30" (same as iOS); `prefix` is localized by the UI. */
        fun defaultTitle(at: Long = System.currentTimeMillis(), prefix: String = "Scan"): String =
            "$prefix " + SimpleDateFormat("yyyy-MM-dd HH.mm", Locale.US).format(Date(at))
    }
}
