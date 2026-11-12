package com.vinhhoang.docsnap.export

import android.graphics.Bitmap
import androidx.exifinterface.media.ExifInterface
import com.vinhhoang.docsnap.data.DocumentStore
import com.vinhhoang.docsnap.model.ScanDocument
import com.vinhhoang.docsnap.processing.PageRenderer
import java.io.File
import java.io.IOException
import java.text.Normalizer
import kotlin.math.ceil

/** Page size for exported PDFs. Auto = each page sized to its image's aspect ratio. */
enum class PdfPageSize { Auto, A4, Letter }

/**
 * Writes a document's processed pages into a PDF.
 *
 * The processed pages are already JPEGs (quality 92), so they are embedded byte-for-byte with
 * [PdfWriter] rather than drawn through android.graphics.pdf.PdfDocument: PdfDocument re-encodes
 * bitmaps losslessly (Flate), which makes PDFs several times larger and needs every page decoded.
 * This way the PDF is about the size of its JPEGs (as on iOS) and memory stays at one copy buffer.
 * A page that is not a plain upright JPEG (rare) is decoded at about 200 DPI for its place on the
 * page, re-encoded to a temporary JPEG and embedded the same way, one page at a time.
 */
object PdfExporter {
    /** Resolution used when a page has to be re-encoded. */
    const val FALLBACK_DPI = 200

    /** Writes `doc`'s processed pages to a PDF in `outputDir`, named after the title; returns the file. */
    fun export(doc: ScanDocument, store: DocumentStore, outputDir: File, pageSize: PdfPageSize = PdfPageSize.Auto): File {
        if (doc.pages.isEmpty()) throw IOException("This document has no pages to export.")
        outputDir.mkdirs()
        val output = File(outputDir, fileName(doc.title) + ".pdf")
        val temps = mutableListOf<File>()
        try {
            PageRenderer.writeAtomically(output) { temp ->
                temp.outputStream().buffered(1 shl 16).use { stream ->
                    val writer = PdfWriter(stream, doc.pages.size, doc.title)
                    doc.pages.forEachIndexed { index, page ->
                        var image = store.processedFile(doc.id, page.id)
                        if (!image.isFile) {
                            // Shouldn't happen (pages are rendered when saved), but don't fail the export over it.
                            val original = store.originalFile(doc.id, page.id)
                            if (!original.isFile) throw IOException("Page ${index + 1} is missing.")
                            image = File(outputDir, ".page-$index.jpg").also { temps += it }
                            PageRenderer.render(original, page, image)
                        }
                        // Opened once: a re-render landing mid-export can't mix two versions of the page.
                        PageSnapshot(image).use { snapshot ->
                            val info = JpegInfo.read(snapshot.open())
                            val upright = info != null && PageRenderer.isUpright(exifOrientation(snapshot))
                            if (info != null && upright) {
                                val (pw, ph) = PdfLayout.pageSize(info.width, info.height, pageSize)
                                writer.addPage(snapshot.open(), snapshot.length, info, pw, ph, PdfLayout.fittedRect(info.width, info.height, pw, ph))
                            } else {
                                val source = File(outputDir, ".pdf-source-$index.jpg").also { temps += it }
                                snapshot.copyTo(source)
                                val (jpeg, encoded) = reencoded(source, pageSize, File(outputDir, ".pdf-page-$index.jpg"), temps)
                                val (pw, ph) = PdfLayout.pageSize(encoded.width, encoded.height, pageSize)
                                writer.addPage(jpeg, encoded, pw, ph, PdfLayout.fittedRect(encoded.width, encoded.height, pw, ph))
                            }
                        }
                        temps.forEach { it.delete() }
                        temps.clear()
                    }
                    writer.finish()
                }
            }
        } finally {
            temps.forEach { it.delete() }
        }
        return output
    }

    /**
     * A file name from the title: keeps Vietnamese (and any other) letters, replaces characters
     * that file systems or share targets reject, trims spaces and dots. Same rules as iOS.
     */
    fun fileName(title: String): String {
        val composed = Normalizer.normalize(title, Normalizer.Form.NFC)
        val sb = StringBuilder()
        for (ch in composed) {
            sb.append(if (ch in INVALID || ch.isISOControl() || ch == ' ' || ch == ' ') '-' else ch)
        }
        val cleaned = sb.toString().trim { it.isWhitespace() || it == '.' }
        if (cleaned.isEmpty()) return "DocSnap"
        // Cut at 100 characters without splitting a surrogate pair.
        if (cleaned.codePointCount(0, cleaned.length) <= MAX_NAME) return cleaned
        return cleaned.substring(0, cleaned.offsetByCodePoints(0, MAX_NAME)).trimEnd { it.isWhitespace() || it == '.' }
    }

    private const val INVALID = "/\\?%*|\"<>:"
    private const val MAX_NAME = 100

    private fun exifOrientation(snapshot: PageSnapshot): Int = try {
        snapshot.open().use { ExifInterface(it).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL) }
    } catch (e: Exception) {
        ExifInterface.ORIENTATION_NORMAL
    }

    /**
     * A page that isn't a plain upright JPEG, re-encoded upright at `temp`. `image` is a private
     * copy (never the live page file), so nothing can change it meanwhile.
     */
    private fun reencoded(image: File, pageSize: PdfPageSize, temp: File, temps: MutableList<File>): Pair<File, JpegInfo> {
        // Size the decode for ~200 DPI where the image lands on the page.
        val bitmapProbe = PageRenderer.imageSize(image)
        val orientation = PageRenderer.exifOrientation(image)
        val swapped = orientation in SWAPPING_ORIENTATIONS
        val w = if (swapped) bitmapProbe.second else bitmapProbe.first
        val h = if (swapped) bitmapProbe.first else bitmapProbe.second
        val (pw, ph) = PdfLayout.pageSize(w, h, pageSize)
        val rect = PdfLayout.fittedRect(w, h, pw, ph)
        val maxDimension = ceil(maxOf(rect.width, rect.height) / 72f * FALLBACK_DPI).toInt()
            .coerceIn(1, PageRenderer.MAX_DIMENSION)

        val bitmap = PageRenderer.decodeUpright(image, maxDimension, orientation = orientation)
        try {
            temps += temp
            temp.outputStream().buffered(1 shl 16).use { out ->
                if (!bitmap.compress(Bitmap.CompressFormat.JPEG, PageRenderer.JPEG_QUALITY, out)) throw IOException("JPEG encode failed")
            }
        } finally {
            bitmap.recycle()
        }
        val encoded = JpegInfo.read(temp) ?: throw IOException("A page image couldn't be read.")
        return temp to encoded
    }

    // ExifInterface.ORIENTATION_TRANSPOSE (5), ROTATE_90 (6), TRANSVERSE (7), ROTATE_270 (8).
    private val SWAPPING_ORIENTATIONS = setOf(5, 6, 7, 8)
}
