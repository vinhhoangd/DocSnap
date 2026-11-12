package com.vinhhoang.docsnap.ui

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.test.performTextReplacement
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.longClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.vinhhoang.docsnap.R
import com.vinhhoang.docsnap.data.LibraryLayout
import com.vinhhoang.docsnap.model.ScanDocument
import com.vinhhoang.docsnap.model.ScanPage
import com.vinhhoang.docsnap.ui.library.LibraryContent
import com.vinhhoang.docsnap.ui.theme.DocSnapTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

@RunWith(AndroidJUnit4::class)
class LibraryContentTest {
    @get:Rule val compose = createComposeRule()

    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private fun s(id: Int, vararg args: Any) = context.getString(id, *args)

    private val now = System.currentTimeMillis()
    private val bill = ScanDocument(id = "bill", title = "Hóa đơn điện", createdAt = now, pages = listOf(ScanPage(id = "p1")))
    private val homework = ScanDocument(id = "hw", title = "Homework", createdAt = now - 1000, pages = listOf(ScanPage(id = "p2"), ScanPage(id = "p3")))

    private val scans = mutableListOf<Unit>()
    private val opened = mutableListOf<String>()
    private val renamed = mutableListOf<Pair<String, String>>()
    private val deleted = mutableListOf<String>()

    private fun show(docs: List<ScanDocument>, layout: LibraryLayout = LibraryLayout.Grid, busy: Boolean = false) {
        compose.setContent {
            DocSnapTheme {
                LibraryContent(
                    documents = docs,
                    layout = layout,
                    thumbnail = { File("/nonexistent/${it.id}.jpg") to 0 },
                    busy = busy,
                    onToggleLayout = {},
                    onScan = { scans += Unit },
                    onOpen = { opened += it },
                    onRename = { id, title -> renamed += id to title },
                    onDelete = { deleted += it },
                    onOpenSettings = {},
                    now = now,
                )
            }
        }
    }

    @Test fun emptyLibraryShowsScanAction() {
        show(emptyList())
        compose.onNodeWithTag("emptyLibrary").assertIsDisplayed()
        compose.onNodeWithText(s(R.string.lib_empty_title)).assertIsDisplayed()
        compose.onNodeWithTag("scanFab").assertDoesNotExist()
        compose.onNodeWithTag("emptyScanButton").assertIsDisplayed().performClick()
        assertEquals(1, scans.size)
    }

    @Test fun emptyLibraryHasSettings() {
        show(emptyList())
        compose.onNodeWithContentDescription(s(R.string.lib_settings)).assertIsDisplayed()
    }

    @Test fun documentsShowWithScanButtonAndTodaySection() {
        show(listOf(bill, homework))
        compose.onNodeWithTag("emptyLibrary").assertDoesNotExist()
        compose.onNodeWithText("Hóa đơn điện").assertIsDisplayed()
        compose.onNodeWithText(s(R.string.lib_section_today)).assertIsDisplayed()
        compose.onNodeWithTag("scanFab").assertIsDisplayed().performClick()
        assertEquals(1, scans.size)
    }

    @Test fun tapOpensDocument() {
        show(listOf(bill))
        compose.onNodeWithTag("document-bill").performClick()
        assertEquals(listOf("bill"), opened)
    }

    @Test fun searchIgnoresAccents() {
        show(listOf(bill, homework))
        compose.onNodeWithTag("searchField").performTextInput("hoa don")
        compose.waitForIdle()
        compose.onNodeWithText("Hóa đơn điện").assertIsDisplayed()
        compose.onNodeWithText("Homework").assertDoesNotExist()
    }

    @Test fun searchWithNoMatchSaysSo() {
        show(listOf(bill))
        compose.onNodeWithTag("searchField").performTextInput("zzz")
        compose.onNodeWithTag("noResults").assertIsDisplayed()
    }

    @Test fun renameFromMenuSavesNewTitle() {
        show(listOf(bill))
        compose.onNodeWithContentDescription(s(R.string.lib_more_actions_for, bill.title)).performClick()
        compose.onNodeWithTag("menuRename").performClick()
        compose.onNodeWithText(s(R.string.lib_rename_title)).assertIsDisplayed()
        compose.onNodeWithTag("renameField").performTextReplacement("  Tiền điện tháng 11  ")
        compose.onNodeWithTag("renameSave").performClick()
        assertEquals(listOf("bill" to "Tiền điện tháng 11"), renamed)
        compose.onNodeWithTag("renameField").assertDoesNotExist()
    }

    @Test fun renameWithBlankNameIsDisabled() {
        show(listOf(bill))
        compose.onNodeWithContentDescription(s(R.string.lib_more_actions_for, bill.title)).performClick()
        compose.onNodeWithTag("menuRename").performClick()
        compose.onNodeWithTag("renameSave").assertIsEnabled()
        compose.onNodeWithTag("renameField").performTextReplacement("   ")
        compose.onNodeWithTag("renameSave").assertIsNotEnabled()
        assertTrue(renamed.isEmpty())
    }

    @Test fun renameCancelChangesNothing() {
        show(listOf(bill))
        compose.onNodeWithContentDescription(s(R.string.lib_more_actions_for, bill.title)).performClick()
        compose.onNodeWithTag("menuRename").performClick()
        compose.onNodeWithText(s(R.string.action_cancel)).performClick()
        compose.onNodeWithTag("renameField").assertDoesNotExist()
        assertTrue(renamed.isEmpty())
    }

    @Test fun longPressOpensMenu() {
        show(listOf(bill), layout = LibraryLayout.List)
        compose.onNodeWithTag("document-bill").performTouchInput { longClick() }
        compose.onNodeWithTag("menuRename").assertIsDisplayed()
        compose.onNodeWithTag("menuDelete").assertIsDisplayed()
    }

    @Test fun deleteAsksFirstThenDeletes() {
        show(listOf(bill))
        compose.onNodeWithContentDescription(s(R.string.lib_more_actions_for, bill.title)).performClick()
        compose.onNodeWithTag("menuDelete").performClick()
        compose.onNodeWithText(s(R.string.lib_delete_doc_title)).assertIsDisplayed()
        compose.onNodeWithText(s(R.string.lib_delete_doc_body, bill.title)).assertIsDisplayed()
        assertTrue(deleted.isEmpty())
        compose.onNodeWithTag("confirmDelete").performClick()
        assertEquals(listOf("bill"), deleted)
    }

    @Test fun deleteCancelKeepsDocument() {
        show(listOf(bill))
        compose.onNodeWithContentDescription(s(R.string.lib_more_actions_for, bill.title)).performClick()
        compose.onNodeWithTag("menuDelete").performClick()
        compose.onNodeWithText(s(R.string.action_cancel)).performClick()
        compose.onNodeWithTag("confirmDelete").assertDoesNotExist()
        assertTrue(deleted.isEmpty())
    }

    @Test fun busyOverlayShowsSaving() {
        show(listOf(bill), busy = true)
        compose.onNodeWithTag("busyOverlay").assertIsDisplayed()
        compose.onNodeWithText(s(R.string.lib_saving)).assertIsDisplayed()
    }
}
