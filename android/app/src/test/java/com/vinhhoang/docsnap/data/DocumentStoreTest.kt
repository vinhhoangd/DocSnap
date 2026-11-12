package com.vinhhoang.docsnap.data

import com.vinhhoang.docsnap.model.PageAnswer
import com.vinhhoang.docsnap.model.ScanDocument
import com.vinhhoang.docsnap.model.ScanFilter
import com.vinhhoang.docsnap.model.ScanPage
import com.vinhhoang.docsnap.model.TextLine
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import java.io.File
import java.nio.file.Files

class DocumentStoreTest {
    private lateinit var root: File
    private lateinit var sources: File
    /** Every render call, as "pageId:filter:rotation". */
    private val renders = mutableListOf<String>()
    private var failRenderOn: Int? = null

    private val fakeRenderer: (File, ScanPage, File) -> Unit = { original, page, output ->
        renders += "${page.id}:${page.filter.raw}:${page.rotation}"
        if (failRenderOn == renders.size) throw IllegalStateException("render failed")
        output.parentFile?.mkdirs()
        output.writeText("processed(${original.readText()},${page.filter.raw},${page.rotation})")
    }

    @Before fun setUp() {
        val base = Files.createTempDirectory("docsnap-store").toFile()
        root = File(base, "documents")
        sources = File(base, "sources").apply { mkdirs() }
    }

    @After fun tearDown() {
        root.parentFile?.deleteRecursively()
    }

    private fun source(name: String): File = File(sources, "$name.jpg").apply { writeText(name) }

    private fun store(dispatcher: TestDispatcher) = DocumentStore(root, fakeRenderer, dispatcher)

    @Test fun createDocumentCopiesPagesRendersAndPersists() = runTest {
        val store = store(StandardTestDispatcher(testScheduler))
        val doc = store.createDocument(listOf(source("a"), source("b")), ScanFilter.Grayscale)

        assertEquals(2, doc.pages.size)
        assertTrue(doc.title.startsWith("Scan "))
        doc.pages.forEachIndexed { i, page ->
            assertEquals(ScanFilter.Grayscale, page.filter)
            assertEquals(listOf("a", "b")[i], store.originalFile(doc.id, page.id).readText())
            assertTrue(store.processedFile(doc.id, page.id).exists())
        }
        assertEquals(listOf(doc), store.documents.value)
        assertTrue(File(store.folder(doc.id), DocumentStore.DOCUMENT_JSON).exists())
        // Sources are copied, not moved: the caller cleans them up.
        assertTrue(File(sources, "a.jpg").exists())
    }

    @Test fun reloadReadsTheSameDocuments() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        val first = store(dispatcher)
        val doc = first.createDocument(listOf(source("a")), ScanFilter.MagicColor, title = "  Hóa đơn tháng 11  ")
        assertEquals("Hóa đơn tháng 11", doc.title)

        val second = store(dispatcher)
        second.load()
        assertEquals(listOf(doc), second.documents.value)
    }

    @Test fun blankTitleFallsBackToDefault() = runTest {
        val store = store(StandardTestDispatcher(testScheduler))
        val doc = store.createDocument(listOf(source("a")), ScanFilter.MagicColor, title = "   ")
        assertTrue(doc.title.startsWith("Scan "))
    }

    @Test fun createWithNoPagesIsRejected() = runTest {
        val store = store(StandardTestDispatcher(testScheduler))
        try {
            store.createDocument(emptyList(), ScanFilter.MagicColor)
            fail("expected IllegalArgumentException")
        } catch (_: IllegalArgumentException) {
        }
        assertTrue(store.documents.value.isEmpty())
    }

    @Test fun failedRenderLeavesNoHalfDocumentBehind() = runTest {
        val store = store(StandardTestDispatcher(testScheduler))
        failRenderOn = 2
        try {
            store.createDocument(listOf(source("a"), source("b")), ScanFilter.MagicColor)
            fail("expected the render failure")
        } catch (_: IllegalStateException) {
        }
        assertTrue(store.documents.value.isEmpty())
        assertTrue(root.listFiles().orEmpty().isEmpty())
    }

    @Test fun addPagesAppendsInOrder() = runTest {
        val store = store(StandardTestDispatcher(testScheduler))
        val doc = store.createDocument(listOf(source("a")), ScanFilter.MagicColor)
        store.addPages(doc.id, listOf(source("b"), source("c")), ScanFilter.BlackWhite)
        val updated = store.document(doc.id)!!
        assertEquals(3, updated.pages.size)
        assertEquals(listOf("a", "b", "c"), updated.pages.map { store.originalFile(doc.id, it.id).readText() })
        assertEquals(ScanFilter.BlackWhite, updated.pages[2].filter)
    }

    @Test fun failedAddPagesKeepsTheDocumentAndRemovesPartialFiles() = runTest {
        val store = store(StandardTestDispatcher(testScheduler))
        val doc = store.createDocument(listOf(source("a")), ScanFilter.MagicColor)
        failRenderOn = 3 // the second of the two added pages
        try {
            store.addPages(doc.id, listOf(source("b"), source("c")), ScanFilter.MagicColor)
            fail("expected the render failure")
        } catch (_: IllegalStateException) {
        }
        assertEquals(1, store.document(doc.id)!!.pages.size)
        assertEquals(1, File(store.folder(doc.id), "original").listFiles()!!.size)
    }

    @Test fun addPagesToADeletedDocumentIsANoOp() = runTest {
        val store = store(StandardTestDispatcher(testScheduler))
        val doc = store.createDocument(listOf(source("a")), ScanFilter.MagicColor)
        store.delete(doc.id)
        store.addPages(doc.id, listOf(source("b")), ScanFilter.MagicColor)
        assertNull(store.document(doc.id))
        assertFalse(store.folder(doc.id).exists())
    }

    @Test fun renameTrimsAndIgnoresBlank() = runTest {
        val store = store(StandardTestDispatcher(testScheduler))
        val doc = store.createDocument(listOf(source("a")), ScanFilter.MagicColor, title = "Old")
        store.rename(doc.id, "  Bài tập Toán  ")
        assertEquals("Bài tập Toán", store.document(doc.id)!!.title)
        store.rename(doc.id, "  ")
        assertEquals("Bài tập Toán", store.document(doc.id)!!.title)
    }

    @Test fun deleteRemovesFilesAndEntry() = runTest {
        val store = store(StandardTestDispatcher(testScheduler))
        val keep = store.createDocument(listOf(source("a")), ScanFilter.MagicColor)
        val gone = store.createDocument(listOf(source("b")), ScanFilter.MagicColor)
        store.delete(gone.id)
        assertEquals(listOf(keep.id), store.documents.value.map { it.id })
        assertFalse(store.folder(gone.id).exists())
    }

    @Test fun deletePageRemovesItsFilesAndTheLastPageDeletesTheDocument() = runTest {
        val store = store(StandardTestDispatcher(testScheduler))
        val doc = store.createDocument(listOf(source("a"), source("b")), ScanFilter.MagicColor)
        val (first, second) = doc.pages
        store.deletePage(doc.id, first.id)
        assertEquals(listOf(second.id), store.document(doc.id)!!.pages.map { it.id })
        assertFalse(store.originalFile(doc.id, first.id).exists())
        assertFalse(store.processedFile(doc.id, first.id).exists())

        store.deletePage(doc.id, "no-such-page")
        assertEquals(1, store.document(doc.id)!!.pages.size)

        store.deletePage(doc.id, second.id)
        assertNull(store.document(doc.id))
        assertFalse(store.folder(doc.id).exists())
    }

    @Test fun movePageReordersAndClamps() = runTest {
        val store = store(StandardTestDispatcher(testScheduler))
        val doc = store.createDocument(listOf(source("a"), source("b"), source("c")), ScanFilter.MagicColor)
        val ids = doc.pages.map { it.id }
        store.movePage(doc.id, 0, 2)
        assertEquals(listOf(ids[1], ids[2], ids[0]), store.document(doc.id)!!.pages.map { it.id })
        store.movePage(doc.id, 2, -5)
        assertEquals(listOf(ids[0], ids[1], ids[2]), store.document(doc.id)!!.pages.map { it.id })
        store.movePage(doc.id, 1, 99)
        assertEquals(listOf(ids[0], ids[2], ids[1]), store.document(doc.id)!!.pages.map { it.id })
        store.movePage(doc.id, 7, 0) // out of range: no change
        assertEquals(listOf(ids[0], ids[2], ids[1]), store.document(doc.id)!!.pages.map { it.id })
    }

    @Test fun editPageRerendersBumpsVersionAndDropsStaleTextAndAnswer() = runTest {
        val store = store(StandardTestDispatcher(testScheduler))
        val doc = store.createDocument(listOf(source("a")), ScanFilter.MagicColor)
        val page = doc.pages.single()
        store.setText(doc.id, page.id, 0, listOf(TextLine("x")))
        store.setAnswer(doc.id, page.id, PageAnswer("ans", "m", 1, 0))
        assertNotNull(store.document(doc.id)!!.pages.single().answer)

        renders.clear()
        store.editPage(doc.id, page.id) { it.copy(filter = ScanFilter.BlackWhite) }
        val edited = store.document(doc.id)!!.pages.single()
        assertEquals(ScanFilter.BlackWhite, edited.filter)
        assertEquals(1, edited.version)
        assertNull(edited.textLines)
        assertNull(edited.answer)
        assertEquals(listOf("${page.id}:blackWhite:0"), renders)
        assertTrue(store.processedFile(doc.id, page.id).readText().contains("blackWhite"))
    }

    @Test fun twoQuickRotationsRotateTwiceAndFourComeBackToZero() = runTest {
        val store = store(StandardTestDispatcher(testScheduler))
        val doc = store.createDocument(listOf(source("a")), ScanFilter.MagicColor)
        val pageId = doc.pages.single().id
        listOf(1, 2).map { async { store.editPage(doc.id, pageId) { it.copy(rotation = it.rotation + 1) } } }.awaitAll()
        assertEquals(2, store.document(doc.id)!!.pages.single().rotation)
        repeat(2) { store.editPage(doc.id, pageId) { it.copy(rotation = it.rotation + 1) } }
        val page = store.document(doc.id)!!.pages.single()
        assertEquals(0, page.rotation)
        assertEquals(4, page.version)
    }

    @Test fun editThatChangesNothingDoesNotRerender() = runTest {
        val store = store(StandardTestDispatcher(testScheduler))
        val doc = store.createDocument(listOf(source("a")), ScanFilter.MagicColor)
        renders.clear()
        store.editPage(doc.id, doc.pages.single().id) { it }
        assertTrue(renders.isEmpty())
        assertEquals(0, store.document(doc.id)!!.pages.single().version)
    }

    @Test fun textAndAnswerForAnOldVersionAreIgnored() = runTest {
        val store = store(StandardTestDispatcher(testScheduler))
        val doc = store.createDocument(listOf(source("a")), ScanFilter.MagicColor)
        val pageId = doc.pages.single().id
        store.editPage(doc.id, pageId) { it.copy(rotation = 1) } // now version 1
        store.setText(doc.id, pageId, 0, listOf(TextLine("stale")))
        store.setAnswer(doc.id, pageId, PageAnswer("stale", "m", 1, 0))
        val page = store.document(doc.id)!!.pages.single()
        assertNull(page.textLines)
        assertNull(page.answer)
        store.setText(doc.id, pageId, 1, listOf(TextLine("Câu 1: Tính đạo hàm")))
        assertEquals("Câu 1: Tính đạo hàm", store.document(doc.id)!!.pages.single().recognizedText)
    }

    @Test fun documentsAreNewestFirst() = runTest {
        val store = store(StandardTestDispatcher(testScheduler))
        val older = store.createDocument(listOf(source("a")), ScanFilter.MagicColor)
        Thread.sleep(5)
        val newer = store.createDocument(listOf(source("b")), ScanFilter.MagicColor)
        assertEquals(listOf(newer.id, older.id), store.documents.value.map { it.id })
        Thread.sleep(5)
        store.rename(older.id, "Touched")
        assertEquals(listOf(older.id, newer.id), store.documents.value.map { it.id })
    }

    @Test fun loadSkipsCorruptOrMismatchedFolders() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        val good = store(dispatcher).createDocument(listOf(source("a")), ScanFilter.MagicColor)
        File(root, "broken").apply { mkdirs() }.resolve(DocumentStore.DOCUMENT_JSON).writeText("{not json")
        File(root, "empty").mkdirs()
        // A document.json whose id doesn't match its folder (e.g. a copied folder).
        File(root, "copy").apply { mkdirs() }.resolve(DocumentStore.DOCUMENT_JSON)
            .writeText(File(store(dispatcher).folder(good.id), DocumentStore.DOCUMENT_JSON).readText())
        File(root, "stray.txt").writeText("x")

        val store = store(dispatcher)
        store.load()
        assertEquals(listOf(good.id), store.documents.value.map { it.id })
        assertTrue(File(root, "broken").exists()) // never deleted automatically
    }

    @Test fun loadToleratesUnknownFieldsAndFilters() = runTest {
        val id = "11111111-2222-3333-4444-555555555555"
        File(root, id).apply { mkdirs() }.resolve(DocumentStore.DOCUMENT_JSON).writeText(
            """{"id":"$id","title":"From a newer app","createdAt":1,"updatedAt":2,"futureField":true,
               "pages":[{"id":"p1","filter":"sepiaFromTheFuture","rotation":1,"quad":{"x":0}}]}""",
        )
        val store = store(StandardTestDispatcher(testScheduler))
        store.load()
        val page = store.document(id)!!.pages.single()
        assertEquals(ScanFilter.MagicColor, page.filter)
        assertEquals(1, page.rotation)
    }

    @Test fun jsonRoundTripKeepsEverything() {
        val doc = ScanDocument(
            title = "Đề thi · 2026",
            createdAt = 10, updatedAt = 20,
            pages = listOf(
                ScanPage(filter = ScanFilter.Lighten, rotation = 3, version = 7,
                    textLines = listOf(TextLine("√2 ≈ 1.414", 0.1f, 0.2f, 0.3f, 0.04f)),
                    answer = PageAnswer("### 1.\n**x = 2**", "claude-opus-5-5", 30, 7)),
            ),
        )
        val json = DocumentStore.json.encodeToString(ScanDocument.serializer(), doc)
        assertTrue(json.contains("\"filter\":\"lighten\""))
        assertEquals(doc, DocumentStore.json.decodeFromString(ScanDocument.serializer(), json))
    }

    @Test fun defaultTitleFormatMatchesIOS() {
        // 2026-11-12 14:30 in the JVM's zone.
        val cal = java.util.Calendar.getInstance().apply { set(2026, 10, 12, 14, 30, 0) }
        assertEquals("Scan 2026-11-12 14.30", ScanDocument.defaultTitle(cal.timeInMillis))
    }

    @Test fun editedNormalizesRotation() {
        val page = ScanPage(rotation = 3)
        assertEquals(0, page.edited(rotation = 4).rotation)
        assertEquals(3, page.edited(rotation = -1).rotation)
        assertEquals(1, page.edited(rotation = 1).version)
    }

    @Test fun allTextJoinsRecognizedPagesInOrder() {
        val doc = ScanDocument(title = "t", pages = listOf(
            ScanPage(textLines = listOf(TextLine("a"), TextLine("b"))),
            ScanPage(),
            ScanPage(textLines = listOf(TextLine("c"))),
        ))
        assertEquals("a\nb\n\nc", doc.allText)
    }
}
