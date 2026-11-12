package com.vinhhoang.docsnap.ui

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextReplacement
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.vinhhoang.docsnap.R
import com.vinhhoang.docsnap.model.ScanDocument
import com.vinhhoang.docsnap.model.ScanPage
import com.vinhhoang.docsnap.ui.document.DocumentContent
import com.vinhhoang.docsnap.ui.theme.DocSnapTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

@RunWith(AndroidJUnit4::class)
class DocumentContentTest {
    @get:Rule val compose = createComposeRule()

    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private fun s(id: Int, vararg args: Any) = context.getString(id, *args)

    private val calls = mutableListOf<String>()

    private fun show(pageCount: Int, busy: String? = null) {
        val doc = ScanDocument(id = "d", title = "Bài tập", pages = (0 until pageCount).map { ScanPage(id = "p$it") })
        compose.setContent {
            DocSnapTheme {
                DocumentContent(
                    doc = doc,
                    pageFile = { File("/nonexistent/${it.id}.jpg") },
                    busyMessage = busy,
                    onBack = { calls += "back" },
                    onOpenPage = { calls += "open $it" },
                    onAddPages = { calls += "add" },
                    onSharePdf = { calls += "pdf" },
                    onShareImages = { calls += "images" },
                    onCopyText = { calls += "copy" },
                    onRename = { calls += "rename $it" },
                    onDelete = { calls += "delete" },
                    onMovePage = { from, to -> calls += "move $from $to" },
                    onRotatePage = { calls += "rotate $it" },
                    onDeletePage = { calls += "deletePage $it" },
                )
            }
        }
    }

    @Test fun bigButtonsAddPagesAndSharePdf() {
        show(2)
        compose.onNodeWithText(s(R.string.lib_doc_add_pages)).assertIsDisplayed()
        compose.onNodeWithTag("addPagesButton").performClick()
        compose.onNodeWithTag("sharePdfButton").performClick()
        assertEquals(listOf("add", "pdf"), calls)
    }

    @Test fun tapPageOpensViewerAtItsIndex() {
        show(3)
        compose.onNodeWithTag("page-1").performClick()
        assertEquals(listOf("open 1"), calls)
    }

    @Test fun firstPageCanOnlyMoveRight() {
        show(3)
        compose.onNodeWithTag("pageMenu-0").performClick()
        compose.onNodeWithTag("menuMoveLeft").assertIsNotEnabled()
        compose.onNodeWithTag("menuMoveRight").assertIsEnabled().performClick()
        assertEquals(listOf("move 0 1"), calls)
    }

    @Test fun lastPageCanOnlyMoveLeft() {
        show(3)
        compose.onNodeWithTag("pageMenu-2").performClick()
        compose.onNodeWithTag("menuMoveRight").assertIsNotEnabled()
        compose.onNodeWithTag("menuMoveLeft").performClick()
        assertEquals(listOf("move 2 1"), calls)
    }

    @Test fun rotatePageFromMenu() {
        show(2)
        compose.onNodeWithTag("pageMenu-1").performClick()
        compose.onNodeWithTag("menuRotate").performClick()
        assertEquals(listOf("rotate p1"), calls)
    }

    @Test fun deletePageAsksFirst() {
        show(2)
        compose.onNodeWithTag("pageMenu-0").performClick()
        compose.onNodeWithTag("menuDeletePage").performClick()
        compose.onNodeWithText(s(R.string.lib_delete_page_title)).assertIsDisplayed()
        compose.onNodeWithText(s(R.string.lib_delete_page_body)).assertIsDisplayed()
        assertTrue(calls.isEmpty())
        compose.onNodeWithTag("confirmDelete").performClick()
        assertEquals(listOf("deletePage p0"), calls)
    }

    @Test fun deletingTheOnlyPageWarnsTheDocumentGoes() {
        show(1)
        compose.onNodeWithTag("pageMenu-0").performClick()
        compose.onNodeWithTag("menuDeletePage").performClick()
        compose.onNodeWithText(s(R.string.lib_delete_last_page_body)).assertIsDisplayed()
    }

    @Test fun renameDocumentFromMenu() {
        show(1)
        compose.onNodeWithTag("documentMenu").performClick()
        compose.onNodeWithTag("menuRename").performClick()
        compose.onNodeWithTag("renameField").performTextReplacement("Bài tập tuần 5")
        compose.onNodeWithTag("renameSave").performClick()
        assertEquals(listOf("rename Bài tập tuần 5"), calls)
    }

    @Test fun deleteDocumentAsksFirst() {
        show(1)
        compose.onNodeWithTag("documentMenu").performClick()
        compose.onNodeWithTag("menuDeleteDocument").performClick()
        compose.onNodeWithText(s(R.string.lib_delete_doc_title)).assertIsDisplayed()
        compose.onNodeWithTag("confirmDelete").performClick()
        assertEquals(listOf("delete"), calls)
    }

    @Test fun menuSharesImagesAndCopiesText() {
        show(1)
        compose.onNodeWithTag("documentMenu").performClick()
        compose.onNodeWithTag("menuShareImages").performClick()
        compose.onNodeWithTag("documentMenu").performClick()
        compose.onNodeWithTag("menuCopyText").performClick()
        assertEquals(listOf("images", "copy"), calls)
    }

    @Test fun busyOverlayShowsMessage() {
        show(1, busy = s(R.string.lib_making_pdf))
        compose.onNodeWithTag("busyOverlay").assertIsDisplayed()
        compose.onNodeWithText(s(R.string.lib_making_pdf)).assertIsDisplayed()
    }
}
