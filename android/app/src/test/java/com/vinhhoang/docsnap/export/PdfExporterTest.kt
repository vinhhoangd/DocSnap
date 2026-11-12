package com.vinhhoang.docsnap.export

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.text.Normalizer

class PdfExporterTest {
    @get:Rule val temp = TemporaryFolder()

    // MARK: - File names

    @Test fun keepsVietnameseLetters() {
        assertEquals("Hóa đơn tiền điện tháng 11", PdfExporter.fileName("Hóa đơn tiền điện tháng 11"))
        assertEquals("Bài tập Đại số tuyến tính", PdfExporter.fileName("Bài tập Đại số tuyến tính"))
    }

    @Test fun replacesCharactersFileSystemsReject() {
        assertEquals("Bài 1-2", PdfExporter.fileName("Bài 1/2"))
        assertEquals("a-b-c-d-e-f-g-h-i-j", PdfExporter.fileName("a/b\\c:d*e?f\"g<h>i|j"))
        assertEquals("50- off", PdfExporter.fileName("50% off"))
        assertEquals("line-break", PdfExporter.fileName("line\nbreak"))
        assertEquals("tab-x", PdfExporter.fileName("tab\tx"))
    }

    @Test fun trimsSpacesAndDots() {
        assertEquals("Scan", PdfExporter.fileName("  Scan  "))
        assertEquals("hidden", PdfExporter.fileName("..hidden.."))
        assertEquals("a. b", PdfExporter.fileName(" a. b. "))
    }

    @Test fun emptyTitlesGetADefault() {
        assertEquals("DocSnap", PdfExporter.fileName(""))
        assertEquals("DocSnap", PdfExporter.fileName("   "))
        assertEquals("DocSnap", PdfExporter.fileName(" . .. "))
    }

    @Test fun composesDecomposedVietnamese() {
        val decomposed = Normalizer.normalize("Tiếng Việt", Normalizer.Form.NFD)
        assertTrue(decomposed.length > "Tiếng Việt".length)
        assertEquals("Tiếng Việt", PdfExporter.fileName(decomposed))
    }

    @Test fun longTitlesAreCutAt100Characters() {
        val name = PdfExporter.fileName("ư".repeat(150))
        assertEquals(100, name.length)
        // never splits an emoji (surrogate pair)
        val emoji = PdfExporter.fileName("a".repeat(99) + "📄" + "b")
        assertEquals(100, emoji.codePointCount(0, emoji.length))
        assertTrue(emoji.endsWith("📄"))
    }

    @Test fun defaultScanTitleIsUnchanged() {
        assertEquals("Scan 2026-11-12 14.30", PdfExporter.fileName("Scan 2026-11-12 14.30"))
    }

    // MARK: - Layout

    @Test fun autoPagesFollowTheImage() {
        assertEquals(595f to 842f, PdfLayout.pageSize(1000, 1414, PdfPageSize.Auto))
        assertEquals(842f to 595f, PdfLayout.pageSize(1414, 1000, PdfPageSize.Auto))
        assertEquals(595f to 595f, PdfLayout.pageSize(3000, 3000, PdfPageSize.Auto))
        // a long receipt keeps its shape
        assertEquals(595f to 1786f, PdfLayout.pageSize(1000, 3000, PdfPageSize.Auto))
    }

    @Test fun fixedSizesTurnForLandscapeImages() {
        assertEquals(595f to 842f, PdfLayout.pageSize(3024, 4032, PdfPageSize.A4))
        assertEquals(842f to 595f, PdfLayout.pageSize(4032, 3024, PdfPageSize.A4))
        assertEquals(612f to 792f, PdfLayout.pageSize(100, 100, PdfPageSize.Letter))
        assertEquals(792f to 612f, PdfLayout.pageSize(200, 100, PdfPageSize.Letter))
    }

    @Test fun imagesAreFittedAndCentred() {
        val square = PdfLayout.fittedRect(1000, 1000, 595f, 842f)
        assertEquals(PdfRect(0f, 123.5f, 595f, 595f), square)
        val tall = PdfLayout.fittedRect(1000, 4000, 612f, 792f)
        assertEquals(198f, tall.width, 1e-3f)
        assertEquals(792f, tall.height, 1e-3f)
        assertEquals((612f - 198f) / 2, tall.x, 1e-3f)
        assertEquals(0f, tall.y, 0f)
    }

    // MARK: - JPEG parsing

    /**
     * A JPEG-shaped file: SOI, APP0 (JFIF), optional APP14 (Adobe), DQT, SOF0, then scan data and
     * EOI. The writer never decodes images, so a well-formed header is all it needs.
     */
    private fun jpegBytes(width: Int, height: Int, components: Int = 3, adobe: Boolean = false, fill: Int = 0x00): ByteArray {
        val out = ByteArrayOutputStream()
        fun seg(marker: Int, body: ByteArray) {
            out.write(0xFF); out.write(marker)
            out.write((body.size + 2) shr 8); out.write((body.size + 2) and 0xFF)
            out.write(body)
        }
        out.write(0xFF); out.write(0xD8)
        seg(0xE0, "JFIF\u0000".toByteArray(Charsets.ISO_8859_1) + byteArrayOf(1, 1, 0, 0, 1, 0, 1, 0, 0))
        if (adobe) seg(0xEE, "Adobe".toByteArray(Charsets.ISO_8859_1) + byteArrayOf(0, 100, 0, 0, 0, 0, 2))
        seg(0xDB, ByteArray(65) { if (it == 0) 0 else 1 })
        out.write(0xFF); out.write(0xFF) // a fill byte before the next marker is legal
        val sof = ByteArrayOutputStream().apply {
            write(8); write(height shr 8); write(height and 0xFF); write(width shr 8); write(width and 0xFF); write(components)
            repeat(components) { write(it + 1); write(0x11); write(0) }
        }.toByteArray()
        seg(0xC0, sof)
        seg(0xDA, byteArrayOf(1, 1, 0, 0, 63, 0))
        repeat(200) { out.write(fill + it % 7) }
        out.write(0xFF); out.write(0xD9)
        return out.toByteArray()
    }

    private fun jpeg(name: String, width: Int, height: Int, components: Int = 3, adobe: Boolean = false): File =
        File(temp.root, name).also { it.writeBytes(jpegBytes(width, height, components, adobe)) }

    @Test fun readsJpegSizeAndComponents() {
        assertEquals(JpegInfo(40, 30, 3, false), JpegInfo.read(jpeg("rgb.jpg", 40, 30)))
        assertEquals(JpegInfo(17, 9, 1, false), JpegInfo.read(jpeg("gray.jpg", 17, 9, components = 1)))
        assertEquals(JpegInfo(4032, 3024, 3, false), JpegInfo.read(jpeg("big.jpg", 4032, 3024)))
        assertEquals(JpegInfo(8, 8, 4, true), JpegInfo.read(jpeg("cmyk.jpg", 8, 8, components = 4, adobe = true)))
        assertEquals(JpegInfo(8, 8, 4, false), JpegInfo.read(jpeg("cmyk2.jpg", 8, 8, components = 4)))
    }

    @Test fun rejectsFilesThatAreNotJpeg() {
        val png = File(temp.root, "a.png").also { it.writeBytes(byteArrayOf(0x89.toByte(), 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13)) }
        assertNull(JpegInfo.read(png))
        assertNull(JpegInfo.read(temp.newFile("empty.jpg")))
        assertNull(JpegInfo.read(File(temp.root, "missing.jpg")))
        val truncated = jpeg("t.jpg", 40, 30).readBytes().copyOf(20)
        assertNull(JpegInfo.read(ByteArrayInputStream(truncated)))
    }

    // MARK: - PDF writing

    private fun writePdf(title: String, vararg pages: Pair<File, PdfPageSize>): ByteArray {
        val bytes = ByteArrayOutputStream()
        val writer = PdfWriter(bytes, pages.size, title)
        for ((file, size) in pages) {
            val info = JpegInfo.read(file)!!
            val (w, h) = PdfLayout.pageSize(info.width, info.height, size)
            writer.addPage(file, info, w, h, PdfLayout.fittedRect(info.width, info.height, w, h))
        }
        writer.finish()
        return bytes.toByteArray()
    }

    private fun ByteArray.latin1() = String(this, Charsets.ISO_8859_1)

    @Test fun writesAWellFormedPdf() {
        val a = jpeg("a.jpg", 300, 400)
        val b = jpeg("b.jpg", 400, 300)
        val pdf = writePdf("Hóa đơn", a to PdfPageSize.A4, b to PdfPageSize.Auto).latin1()
        assertTrue(pdf.startsWith("%PDF-1.4\n"))
        assertTrue(pdf.endsWith("%%EOF\n"))
        assertTrue(pdf.contains("/Type /Pages /Kids [4 0 R 7 0 R] /Count 2"))
        assertTrue(pdf.contains("/MediaBox [0 0 595 842]"))
        assertTrue(pdf.contains("/MediaBox [0 0 793.71 595.28]") || pdf.contains("/MediaBox [0 0 794 595]"))
        assertTrue(pdf.contains("/Width 300 /Height 400 /ColorSpace /DeviceRGB"))
        assertTrue(pdf.contains("/Filter /DCTDecode"))

        // startxref points at the table, and every entry points at its object.
        val startxref = Regex("startxref\n(\\d+)\n").find(pdf)!!.groupValues[1].toInt()
        assertTrue(pdf.startsWith("xref\n", startxref))
        val entries = Regex("(\\d{10}) 00000 n ").findAll(pdf.substring(startxref)).map { it.groupValues[1].toInt() }.toList()
        assertEquals(3 + 3 * 2, entries.size)
        entries.forEachIndexed { i, offset -> assertTrue("object ${i + 1}", pdf.startsWith("${i + 1} 0 obj\n", offset)) }
        assertTrue(pdf.contains("/Size 10 /Root 1 0 R /Info 3 0 R"))
    }

    @Test fun embedsTheJpegBytesUnchangedWithTheRightLength() {
        val a = jpeg("a.jpg", 64, 48)
        val raw = a.readBytes()
        val pdf = writePdf("x", a to PdfPageSize.Auto)
        val text = pdf.latin1()
        val start = text.indexOf(raw.latin1())
        assertTrue("JPEG bytes embedded verbatim", start > 0)
        assertTrue(text.contains("/Length ${raw.size} >>\nstream\n"))
        assertTrue(text.startsWith("\nendstream", start + raw.size))
    }

    @Test fun aPageReRenderedMidExportDoesNotMixTwoVersions() {
        // Regression: the JPEG header and the bytes were read through two separate opens, so a
        // re-render (new file renamed over the old) in between gave one version's size and the
        // other's bytes. A snapshot reads both from the one open file.
        val page = jpeg("page.jpg", 40, 30)
        val before = page.readBytes()
        val bytes = ByteArrayOutputStream()
        PageSnapshot(page).use { snapshot ->
            val info = JpegInfo.read(snapshot.open())!!
            // The re-render lands: a bigger image replaces the file by rename, as PageRenderer does.
            val rerender = File(temp.root, ".page.jpg.tmp").apply { writeBytes(jpegBytes(80, 60, fill = 0x40) + ByteArray(500)) }
            java.nio.file.Files.move(rerender.toPath(), page.toPath(), java.nio.file.StandardCopyOption.REPLACE_EXISTING)
            assertEquals(80, JpegInfo.read(page)!!.width)

            val writer = PdfWriter(bytes, 1, "x")
            writer.addPage(snapshot.open(), snapshot.length, info, 40f, 30f, PdfRect(0f, 0f, 40f, 30f))
            writer.finish()
        }
        val pdf = bytes.toByteArray().latin1()
        assertTrue(pdf.contains("/Width 40 /Height 30 "))
        assertTrue(pdf.contains("/Length ${before.size} >>\nstream\n"))
        val start = pdf.indexOf(before.latin1())
        assertTrue("the opened version is embedded whole", start > 0)
        assertTrue(pdf.startsWith("\nendstream", start + before.size))
    }

    @Test fun snapshotStreamsCanBeReadMoreThanOnce() {
        val page = jpeg("page.jpg", 12, 8)
        PageSnapshot(page).use { snapshot ->
            assertEquals(JpegInfo(12, 8, 3, false), JpegInfo.read(snapshot.open()))
            assertEquals(page.length(), snapshot.length)
            val copy = File(temp.root, "copy.jpg")
            snapshot.copyTo(copy)
            assertTrue(copy.readBytes().contentEquals(page.readBytes()))
            snapshot.open().use { } // closing a stream leaves the snapshot usable
            assertEquals(JpegInfo(12, 8, 3, false), JpegInfo.read(snapshot.open()))
        }
    }

    @Test fun placesTheImageWithABottomLeftOrigin() {
        val square = jpeg("sq.jpg", 100, 100)
        val pdf = writePdf("x", square to PdfPageSize.A4).latin1()
        // 595 × 595 image, centred on an 842 pt page: 123.5 pt from the bottom.
        assertTrue(pdf, pdf.contains("q 595 0 0 595 0 123.5 cm /Im0 Do Q"))
    }

    @Test fun adobeCmykJpegsAreInverted() {
        val cmyk = jpeg("c.jpg", 20, 20, components = 4, adobe = true)
        assertTrue(writePdf("x", cmyk to PdfPageSize.Auto).latin1().contains("/ColorSpace /DeviceCMYK /Decode [1 0 1 0 1 0 1 0]"))
    }

    @Test fun grayJpegsUseDeviceGray() {
        val gray = jpeg("g.jpg", 20, 20, components = 1)
        assertTrue(writePdf("x", gray to PdfPageSize.Auto).latin1().contains("/ColorSpace /DeviceGray"))
    }

    @Test fun titleIsStoredAsUtf16() {
        val pdf = writePdf("Hóa đơn", jpeg("a.jpg", 10, 10) to PdfPageSize.Auto).latin1()
        val hex = Regex("/Title <([0-9A-F]+)>").find(pdf)!!.groupValues[1]
        val bytes = hex.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
        assertEquals("Hóa đơn", String(bytes, Charsets.UTF_16))
    }

    @Test fun numbersNeverUseExponents() {
        assertEquals("0", PdfWriter.num(0f))
        assertEquals("0", PdfWriter.num(-0.001f))
        assertEquals("123.5", PdfWriter.num(123.5f))
        assertEquals("595.28", PdfWriter.num(595.28f))
        assertEquals("100000", PdfWriter.num(1e5f))
        assertEquals("0.01", PdfWriter.num(0.01f))
    }

    @Test fun missingPagesFailFinish() {
        val writer = PdfWriter(ByteArrayOutputStream(), 2, "x")
        val a = jpeg("a.jpg", 10, 10)
        writer.addPage(a, JpegInfo.read(a)!!, 10f, 10f, PdfRect(0f, 0f, 10f, 10f))
        var failed = false
        try {
            writer.finish()
        } catch (_: IllegalStateException) {
            failed = true
        }
        assertTrue(failed)
    }

    @Test fun zeroPagesAreRejected() {
        var failed = false
        try {
            PdfWriter(ByteArrayOutputStream(), 0, "x")
        } catch (_: IllegalArgumentException) {
            failed = true
        }
        assertTrue(failed)
        assertFalse(File(temp.root, "x.pdf").exists())
    }
}
