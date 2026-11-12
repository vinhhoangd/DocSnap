package com.vinhhoang.docsnap.ui.page

import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.Rotate90DegreesCw
import androidx.compose.material.icons.filled.Share
import androidx.compose.material.icons.filled.TextFields
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.vinhhoang.docsnap.DocSnapApp
import com.vinhhoang.docsnap.R
import com.vinhhoang.docsnap.model.ScanFilter
import com.vinhhoang.docsnap.model.ScanPage
import com.vinhhoang.docsnap.ocr.TextRecognizer
import com.vinhhoang.docsnap.ui.answer.AnswerSheet
import com.vinhhoang.docsnap.ui.common.BusyPill
import com.vinhhoang.docsnap.ui.common.ConfirmDeleteDialog
import com.vinhhoang.docsnap.ui.common.LeaveWhenGone
import com.vinhhoang.docsnap.ui.common.MessageDialog
import com.vinhhoang.docsnap.ui.common.PageImage
import com.vinhhoang.docsnap.ui.common.PageImageCache
import com.vinhhoang.docsnap.ui.share.Sharing
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PageViewerScreen(documentId: String, startIndex: Int, onBack: () -> Unit) {
    val context = LocalContext.current
    val app = context.applicationContext as DocSnapApp
    val store = app.store
    val documents by store.documents.collectAsStateWithLifecycle()
    val storeLoaded by store.loaded.collectAsStateWithLifecycle()
    val doc = documents.firstOrNull { it.id == documentId }
    val scope = rememberCoroutineScope()

    var pendingEdits by remember { mutableIntStateOf(0) }
    var textPageId by rememberSaveable { mutableStateOf<String?>(null) }
    var answerPageId by rememberSaveable { mutableStateOf<String?>(null) }
    var deletePageId by rememberSaveable { mutableStateOf<String?>(null) }
    var message by rememberSaveable { mutableStateOf<String?>(null) }
    var zoomedPage by remember { mutableStateOf<Int?>(null) }
    // The filter just tapped, shown as selected while it renders (page id to filter).
    var pickedFilter by remember { mutableStateOf<Pair<String, ScanFilter>?>(null) }

    LeaveWhenGone(present = doc != null, loaded = storeLoaded, onGone = onBack)
    if (doc == null || doc.pages.isEmpty()) return
    val pages = doc.pages

    val pagerState = rememberPagerState(initialPage = startIndex.coerceIn(0, pages.lastIndex)) { pages.size }
    val current: ScanPage = pages[pagerState.currentPage.coerceIn(0, pages.lastIndex)]

    /** Store edits finish even if the user leaves; the pill shows while any is rendering. */
    fun edit(page: ScanPage, onDone: () -> Unit = {}, change: (ScanPage) -> ScanPage) {
        scope.launch {
            pendingEdits++
            try {
                withContext(NonCancellable) { store.editPage(documentId, page.id, change) }
            } catch (_: Throwable) {
                message = context.getString(R.string.error_generic)
            } finally {
                pendingEdits--
                onDone()
            }
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, stringResource(R.string.action_back))
                    }
                },
                title = {
                    val spoken = stringResource(R.string.lib_viewer_position_spoken, pagerState.currentPage + 1, pages.size)
                    Text(
                        stringResource(R.string.lib_viewer_position, pagerState.currentPage + 1, pages.size),
                        modifier = Modifier.semantics { contentDescription = spoken }.testTag("pagePosition"),
                    )
                },
            )
        },
        bottomBar = {
            Surface(tonalElevation = 3.dp) {
                Column(Modifier.navigationBarsPadding()) {
                    val shownFilter = pickedFilter?.takeIf { it.first == current.id }?.second ?: current.filter
                    FilterStrip(
                        selected = shownFilter,
                        onSelect = { f ->
                            val picked = current.id to f
                            pickedFilter = picked
                            edit(current, onDone = { if (pickedFilter == picked) pickedFilter = null }) { it.copy(filter = f) }
                        },
                    )
                    Row(Modifier.fillMaxWidth().padding(horizontal = 4.dp, vertical = 4.dp)) {
                        ViewerAction(Icons.Filled.Rotate90DegreesCw, R.string.lib_page_rotate, "rotateButton") {
                            edit(current) { it.copy(rotation = it.rotation + 1) }
                        }
                        ViewerAction(Icons.Filled.TextFields, R.string.lib_viewer_text, "textButton") { textPageId = current.id }
                        ViewerAction(Icons.Filled.AutoAwesome, R.string.answer_button, "answerButton") { answerPageId = current.id }
                        ViewerAction(Icons.Outlined.Delete, R.string.action_delete, "deletePageButton", destructive = true) {
                            deletePageId = current.id
                        }
                    }
                }
            }
        },
    ) { padding ->
        Box(Modifier.padding(padding).fillMaxSize().background(MaterialTheme.colorScheme.surfaceVariant)) {
            HorizontalPager(
                state = pagerState,
                key = { pages.getOrNull(it)?.id ?: it },
                userScrollEnabled = zoomedPage != pagerState.currentPage,
                beyondViewportPageCount = 1,
                modifier = Modifier.fillMaxSize().testTag("pagePager"),
            ) { index ->
                val page = pages.getOrNull(index) ?: return@HorizontalPager
                ZoomablePage(
                    isCurrent = index == pagerState.currentPage,
                    onZoomedChange = { zoomed -> zoomedPage = if (zoomed) index else null },
                ) {
                    PageImage(
                        file = store.processedFile(documentId, page.id),
                        version = page.version,
                        contentDescription = stringResource(R.string.lib_page_number, index + 1),
                        maxSide = PageImageCache.viewerMaxSide,
                        modifier = Modifier.fillMaxSize().padding(12.dp),
                    )
                }
            }
            if (pendingEdits > 0) {
                BusyPill(stringResource(R.string.lib_applying), Modifier.align(Alignment.TopCenter).padding(top = 12.dp))
            }
        }
    }

    // Sheets for a page that was deleted meanwhile simply aren't shown.
    pages.firstOrNull { it.id == textPageId }?.let { page ->
        TextSheet(page = page, documentId = documentId, title = doc.title, onDismiss = { textPageId = null })
    }
    pages.firstOrNull { it.id == answerPageId }?.let { page ->
        AnswerSheet(documentId = documentId, pageId = page.id, onDismiss = { answerPageId = null })
    }
    deletePageId?.let { pageId ->
        ConfirmDeleteDialog(
            title = stringResource(R.string.lib_delete_page_title),
            message = stringResource(if (pages.size <= 1) R.string.lib_delete_last_page_body else R.string.lib_delete_page_body),
            onConfirm = {
                deletePageId = null
                app.appScope.launch {
                    try {
                        store.deletePage(documentId, pageId)
                    } catch (e: CancellationException) {
                        throw e
                    } catch (_: Throwable) {
                        message = context.getString(R.string.error_generic)
                    }
                }
            },
            onDismiss = { deletePageId = null },
        )
    }
    message?.let { MessageDialog(it, onDismiss = { message = null }) }
}

/** The display name of a filter. */
fun filterLabel(filter: ScanFilter): Int = when (filter) {
    ScanFilter.Original -> R.string.filter_original
    ScanFilter.MagicColor -> R.string.filter_magic_color
    ScanFilter.Grayscale -> R.string.filter_grayscale
    ScanFilter.BlackWhite -> R.string.filter_black_white
    ScanFilter.Lighten -> R.string.filter_lighten
}

/** The five page looks as big chips; the selected one is checked. Tag: "filter-<raw>". */
@Composable
fun FilterStrip(selected: ScanFilter, onSelect: (ScanFilter) -> Unit, modifier: Modifier = Modifier) {
    val label = stringResource(R.string.lib_filters)
    Row(
        modifier
            .fillMaxWidth()
            .horizontalScroll(rememberScrollState())
            .padding(horizontal = 12.dp, vertical = 4.dp)
            .selectableGroup()
            .semantics { contentDescription = label }
            .testTag("filterStrip"),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        ScanFilter.entries.forEach { filter ->
            val isSelected = filter == selected
            FilterChip(
                selected = isSelected,
                onClick = { if (!isSelected) onSelect(filter) },
                label = { Text(stringResource(filterLabel(filter)), style = MaterialTheme.typography.titleSmall) },
                leadingIcon = if (isSelected) {
                    { Icon(Icons.Filled.Check, contentDescription = null, modifier = Modifier.size(18.dp)) }
                } else {
                    null
                },
                modifier = Modifier.heightIn(min = 48.dp).testTag("filter-${filter.raw}"),
            )
        }
    }
}

@Composable
private fun androidx.compose.foundation.layout.RowScope.ViewerAction(
    icon: ImageVector,
    label: Int,
    tag: String,
    destructive: Boolean = false,
    onClick: () -> Unit,
) {
    val color = if (destructive) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurface
    TextButton(
        onClick = onClick,
        contentPadding = PaddingValues(vertical = 8.dp),
        modifier = Modifier.weight(1f).heightIn(min = 64.dp).testTag(tag),
    ) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Icon(icon, contentDescription = null, tint = color, modifier = Modifier.size(26.dp))
            Text(
                stringResource(label),
                style = MaterialTheme.typography.labelLarge,
                color = color,
                textAlign = TextAlign.Center,
                // Two lines, so long Vietnamese labels at large font sizes wrap instead of clipping.
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

private sealed interface OcrState {
    data object Loading : OcrState
    data object Failed : OcrState
    data class Ready(val text: String) : OcrState
}

/** Text on the page: read with OCR the first time (and saved), then copy or share it. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun TextSheet(page: ScanPage, documentId: String, title: String, onDismiss: () -> Unit) {
    val context = LocalContext.current
    val store = (context.applicationContext as DocSnapApp).store
    var attempt by remember { mutableIntStateOf(0) }
    var state by remember(page.id) {
        mutableStateOf<OcrState>(page.recognizedText?.let { OcrState.Ready(it) } ?: OcrState.Loading)
    }

    LaunchedEffect(page.id, page.version, attempt) {
        page.recognizedText?.let {
            state = OcrState.Ready(it)
            return@LaunchedEffect
        }
        state = OcrState.Loading
        state = try {
            val lines = withContext(Dispatchers.IO) { TextRecognizer.recognize(store.processedFile(documentId, page.id)) }
            withContext(NonCancellable) { store.setText(documentId, page.id, page.version, lines) }
            OcrState.Ready(lines.joinToString("\n") { it.text })
        } catch (e: CancellationException) {
            throw e
        } catch (_: Throwable) {
            OcrState.Failed
        }
    }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        modifier = Modifier.testTag("textSheet"),
    ) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 24.dp).padding(bottom = 24.dp)) {
            Text(stringResource(R.string.lib_text_title), style = MaterialTheme.typography.titleLarge)
            Spacer(Modifier.size(16.dp))
            when (val s = state) {
                OcrState.Loading -> Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(vertical = 24.dp)) {
                    CircularProgressIndicator(Modifier.size(28.dp))
                    Spacer(Modifier.width(16.dp))
                    Text(stringResource(R.string.lib_reading_text), style = MaterialTheme.typography.bodyLarge)
                }
                OcrState.Failed -> Column {
                    Text(stringResource(R.string.lib_text_error), style = MaterialTheme.typography.bodyLarge)
                    Spacer(Modifier.size(16.dp))
                    Button(onClick = { attempt++ }, modifier = Modifier.heightIn(min = 56.dp)) {
                        Text(stringResource(R.string.lib_text_retry), style = MaterialTheme.typography.titleMedium)
                    }
                }
                is OcrState.Ready -> if (s.text.isBlank()) {
                    Text(stringResource(R.string.lib_text_none), style = MaterialTheme.typography.bodyLarge)
                } else {
                    Box(Modifier.heightIn(max = 420.dp).verticalScroll(rememberScrollState())) {
                        SelectionContainer {
                            Text(s.text, style = MaterialTheme.typography.bodyLarge, modifier = Modifier.testTag("recognizedText"))
                        }
                    }
                    Spacer(Modifier.size(16.dp))
                    Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        Button(
                            onClick = { Sharing.copyText(context, title, s.text) },
                            modifier = Modifier.weight(1f).heightIn(min = 56.dp).testTag("copyTextButton"),
                        ) {
                            Icon(Icons.Filled.ContentCopy, contentDescription = null)
                            Spacer(Modifier.width(8.dp))
                            Text(stringResource(R.string.lib_text_copy), style = MaterialTheme.typography.titleMedium)
                        }
                        OutlinedButton(
                            onClick = { Sharing.shareText(context, s.text, title) },
                            modifier = Modifier.weight(1f).heightIn(min = 56.dp).testTag("shareTextButton"),
                        ) {
                            Icon(Icons.Filled.Share, contentDescription = null)
                            Spacer(Modifier.width(8.dp))
                            Text(stringResource(R.string.lib_text_share), style = MaterialTheme.typography.titleMedium)
                        }
                    }
                }
            }
        }
    }
}

