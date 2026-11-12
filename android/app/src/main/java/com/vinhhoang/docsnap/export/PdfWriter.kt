package com.vinhhoang.docsnap.export

import java.io.Closeable
import java.io.File
import java.io.FileInputStream
import java.io.FilterInputStream
import java.io.FilterOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.util.Locale
import kotlin.math.roundToInt

/** A rectangle in PDF points (1/72 inch); `x`/`y` from the page's top-left. */
data class PdfRect(val x: Float, val y: Float, val width: Float, val height: Float)

/** Page geometry, the same rules as the iPhone app's PDFExporter. */
object PdfLayout {
    const val A4_WIDTH = 595f
    const val A4_HEIGHT = 842f
    const val LETTER_WIDTH = 612f
    const val LETTER_HEIGHT = 792f
    /** Auto pages get A4's short side (iOS uses 595.28). */
    const val AUTO_SHORT_SIDE = 595.28f

    /** Page size in points for an image: landscape images get a landscape page. */
    fun pageSize(imageWidth: Int, imageHeight: Int, pageSize: PdfPageSize): Pair<Float, Float> {
        val landscape = imageWidth > imageHeight
        val portrait = when (pageSize) {
            PdfPageSize.A4 -> A4_WIDTH to A4_HEIGHT
            PdfPageSize.Letter -> LETTER_WIDTH to LETTER_HEIGHT
            PdfPageSize.Auto -> {
                val scale = AUTO_SHORT_SIDE / maxOf(1, minOf(imageWidth, imageHeight))
                return maxOf(1f, (imageWidth * scale).roundToInt().toFloat()) to maxOf(1f, (imageHeight * scale).roundToInt().toFloat())
            }
        }
        return if (landscape) portrait.second to portrait.first else portrait
    }

    /** The image aspect-fit and centred in a page of `pageWidth` × `pageHeight`. */
    fun fittedRect(imageWidth: Int, imageHeight: Int, pageWidth: Float, pageHeight: Float): PdfRect {
        val scale = minOf(pageWidth / imageWidth, pageHeight / imageHeight)
        val w = imageWidth * scale
        val h = imageHeight * scale
        return PdfRect((pageWidth - w) / 2, (pageHeight - h) / 2, w, h)
    }
}

/** What a PDF needs to embed a JPEG as-is: its size and colour components (from the SOF marker). */
data class JpegInfo(val width: Int, val height: Int, val components: Int, val adobeInverted: Boolean) {
    companion object {
        fun read(file: File): JpegInfo? = try {
            file.inputStream().buffered().use { read(it) }
        } catch (e: IOException) {
            null
        }

        /** Parses markers up to the first start-of-frame. Null if this isn't a usable JPEG. */
        fun read(input: InputStream): JpegInfo? {
            if (input.read() != 0xFF || input.read() != 0xD8) return null
            var adobe = false
            while (true) {
                var b = input.read()
                if (b < 0) return null
                if (b != 0xFF) return null
                while (b == 0xFF) b = input.read() // fill bytes
                if (b < 0) return null
                val marker = b
                if (marker == 0x01 || marker in 0xD0..0xD7) continue // no length
                if (marker == 0xD9 || marker == 0xDA) return null // end / scan before any frame
                val length = (input.read() shl 8) or input.read()
                if (length < 2) return null
                val isSof = marker in 0xC0..0xCF && marker != 0xC4 && marker != 0xC8 && marker != 0xCC
                if (isSof) {
                    val precision = input.read()
                    val height = (input.read() shl 8) or input.read()
                    val width = (input.read() shl 8) or input.read()
                    val components = input.read()
                    if (precision != 8 || width <= 0 || height <= 0 || components !in intArrayOf(1, 3, 4)) return null
                    return JpegInfo(width, height, components, adobe && components == 4)
                }
                val body = ByteArray(length - 2)
                if (readFully(input, body) != body.size) return null
                if (marker == 0xEE && body.size >= 5 && String(body, 0, 5, Charsets.US_ASCII) == "Adobe") adobe = true
            }
        }

        private fun readFully(input: InputStream, buffer: ByteArray): Int {
            var off = 0
            while (off < buffer.size) {
                val n = input.read(buffer, off, buffer.size - off)
                if (n < 0) break
                off += n
            }
            return off
        }
    }
}

/**
 * A page image opened once, so its size, JPEG header, EXIF and bytes all come from the same version
 * of the file. Pages are re-rendered by writing a new file and renaming it over the old one, so an
 * open file never changes underneath; reading it twice by path could mix two versions.
 */
class PageSnapshot(file: File) : Closeable {
    private val input = FileInputStream(file)
    private val channel = input.channel

    /** Size of the opened version, in bytes. */
    val length: Long = channel.size()

    /** A fresh stream over the whole opened version. Closing it does not close the snapshot; use one at a time. */
    fun open(): InputStream {
        channel.position(0)
        val raw = object : FilterInputStream(java.nio.channels.Channels.newInputStream(channel)) {
            override fun close() = Unit
        }
        return raw.buffered(1 shl 16)
    }

    /** Copies the opened version to `target` (for code that needs a path, like BitmapFactory). */
    fun copyTo(target: File) {
        target.outputStream().use { out -> open().copyTo(out, 1 shl 16) }
    }

    override fun close() = input.close()
}

/**
 * A minimal PDF 1.4 writer whose pages are JPEG images embedded byte-for-byte (DCTDecode), like
 * the iPhone app's PDFs: no decoding, no quality loss, the PDF is about the size of its JPEGs,
 * and memory use is one 64 KB copy buffer however many pages there are.
 *
 * Object numbers: 1 catalog, 2 page tree, 3 info, then 3 per page (page, contents, image).
 */
class PdfWriter(private val out: OutputStream, private val pageCount: Int, title: String) {
    private val stream = CountingStream(out)
    private val offsets = LongArray(3 + 3 * pageCount + 1)
    private var written = 0

    init {
        require(pageCount > 0) { "A PDF needs at least one page" }
        stream.write("%PDF-1.4\n%âãÏÓ\n".toByteArray(Charsets.ISO_8859_1))
        obj(1, "<< /Type /Catalog /Pages 2 0 R >>")
        val kids = (0 until pageCount).joinToString(" ") { "${pageObj(it)} 0 R" }
        obj(2, "<< /Type /Pages /Kids [$kids] /Count $pageCount >>")
        obj(3, "<< /Title ${textString(title)} /Creator (DocSnap) /Producer (DocSnap) >>")
    }

    /** Adds the next page: `jpeg` drawn into `rect` on a `pageWidth` × `pageHeight` page. */
    fun addPage(jpeg: File, info: JpegInfo, pageWidth: Float, pageHeight: Float, rect: PdfRect) {
        // One open: the length and the bytes come from the same version of the file.
        FileInputStream(jpeg).use { input -> addPage(input, input.channel.size(), info, pageWidth, pageHeight, rect) }
    }

    /**
     * Adds the next page from `jpeg`, which must deliver exactly `length` bytes (it is not closed).
     * `info` must describe these same bytes; see [PageSnapshot].
     */
    fun addPage(jpeg: InputStream, length: Long, info: JpegInfo, pageWidth: Float, pageHeight: Float, rect: PdfRect) {
        check(written < pageCount) { "More pages than declared" }
        val n = pageObj(written)
        obj(n, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 ${num(pageWidth)} ${num(pageHeight)}] " +
            "/Resources << /XObject << /Im0 ${n + 2} 0 R >> >> /Contents ${n + 1} 0 R >>")
        // PDF space has a bottom-left origin.
        val content = "q ${num(rect.width)} 0 0 ${num(rect.height)} ${num(rect.x)} ${num(pageHeight - rect.y - rect.height)} cm /Im0 Do Q\n"
            .toByteArray(Charsets.US_ASCII)
        begin(n + 1)
        write("<< /Length ${content.size} >>\nstream\n")
        stream.write(content)
        write("\nendstream\nendobj\n")

        val colour = when (info.components) {
            1 -> "/DeviceGray"
            4 -> "/DeviceCMYK" + if (info.adobeInverted) " /Decode [1 0 1 0 1 0 1 0]" else ""
            else -> "/DeviceRGB"
        }
        begin(n + 2)
        write("<< /Type /XObject /Subtype /Image /Width ${info.width} /Height ${info.height} /ColorSpace $colour " +
            "/BitsPerComponent 8 /Filter /DCTDecode /Length $length >>\nstream\n")
        val copied = jpeg.copyTo(stream, 1 shl 16)
        if (copied != length) throw IOException("A page image changed while exporting")
        write("\nendstream\nendobj\n")
        written++
    }

    /** Writes the cross-reference table and trailer (does not close `out`). Every declared page must have been added. */
    fun finish() {
        check(written == pageCount) { "Only $written of $pageCount pages were added" }
        val xref = stream.count
        val size = offsets.size
        val sb = StringBuilder("xref\n0 $size\n0000000000 65535 f \n")
        for (i in 1 until size) sb.append(String.format(Locale.US, "%010d 00000 n \n", offsets[i]))
        sb.append("trailer\n<< /Size $size /Root 1 0 R /Info 3 0 R >>\nstartxref\n$xref\n%%EOF\n")
        write(sb.toString())
        stream.flush()
    }

    private fun pageObj(index: Int) = 4 + 3 * index

    private fun begin(n: Int) {
        offsets[n] = stream.count
        write("$n 0 obj\n")
    }

    private fun obj(n: Int, body: String) {
        begin(n)
        write(body)
        write("\nendobj\n")
    }

    private fun write(s: String) = stream.write(s.toByteArray(Charsets.ISO_8859_1))

    private class CountingStream(out: OutputStream) : FilterOutputStream(out) {
        var count = 0L
            private set

        override fun write(b: Int) {
            out.write(b)
            count++
        }

        override fun write(b: ByteArray, off: Int, len: Int) {
            out.write(b, off, len)
            count += len
        }
    }

    companion object {
        /** A number with at most 2 decimals, never in exponent form. */
        internal fun num(v: Float): String {
            val s = String.format(Locale.US, "%.2f", v).trimEnd('0').trimEnd('.')
            return if (s == "-0") "0" else s
        }

        /** A PDF text string in UTF-16BE with a byte-order mark (keeps Vietnamese titles intact). */
        internal fun textString(text: String): String {
            val sb = StringBuilder("<FEFF")
            for (ch in text) sb.append(String.format(Locale.US, "%04X", ch.code))
            return sb.append('>').toString()
        }
    }
}
