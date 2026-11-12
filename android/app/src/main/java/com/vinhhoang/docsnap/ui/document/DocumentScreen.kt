package com.vinhhoang.docsnap.ui.document

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowLeft
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.AddAPhoto
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.PhotoLibrary
import androidx.compose.material.icons.filled.PictureAsPdf
import androidx.compose.material.icons.filled.Rotate90DegreesCw
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.vinhhoang.docsnap.DocSnapApp
import com.vinhhoang.docsnap.R
import com.vinhhoang.docsnap.model.ScanDocument
import com.vinhhoang.docsnap.model.ScanPage
import androidx.lifecycle.Lifecycle
import com.vinhhoang.docsnap.scan.openPlayServicesInStore
import com.vinhhoang.docsnap.scan.rememberScanner
import com.vinhhoang.docsnap.ui.common.BusyOverlay
import com.vinhhoang.docsnap.ui.common.CollectEvents
import com.vinhhoang.docsnap.ui.common.ConfirmDeleteDialog
import com.vinhhoang.docsnap.ui.common.LeaveWhenGone
import com.vinhhoang.docsnap.ui.common.MessageDialog
import com.vinhhoang.docsnap.ui.common.PageImage
import com.vinhhoang.docsnap.ui.common.PageOrder
import com.vinhhoang.docsnap.ui.common.RenameDialog
import com.vinhhoang.docsnap.ui.share.Sharing
import java.io.File

@Composable
fun DocumentScreen(documentId: String, onBack: () -> Unit, onOpenPage: (documentId: String, index: Int) -> Unit) {
    val context = LocalContext.current
    val app = context.applicationContext as DocSnapApp
    val vm: DocumentViewModel = viewModel(key = "document-$documentId")
    val documents by app.store.documents.collectAsStateWithLifecycle()
    val storeLoaded by app.store.loaded.collectAsStateWithLifecycle()
    val doc = documents.firstOrNull { it.id == documentId }
    val busy by vm.busy.collectAsStateWithLifecycle()
    var message by rememberSaveable { mutableStateOf<String?>(null) }
    // The message is a scanner error that the Play Store can fix ("Update" button).
    var offerUpdate by rememberSaveable { mutableStateOf(false) }

    LeaveWhenGone(present = doc != null, loaded = storeLoaded, onGone = onBack)

    val scanner = rememberScanner(
        onPages = { vm.addPages(documentId, it) },
        onError = {
            message = context.getString(it.message)
            offerUpdate = it.offersPlayServicesUpdate
        },
    )

    // Only while the screen is visible: a share sheet started from a stopped activity never shows.
    CollectEvents(vm.events, Lifecycle.State.STARTED) { event ->
        offerUpdate = false
        when (event) {
            is DocumentEvent.Share ->
                if (!Sharing.shareFiles(context, event.files, event.mime, event.subject)) {
                    message = context.getString(R.string.lib_no_share_app)
                }
            is DocumentEvent.CopyText -> Sharing.copyText(context, event.label, event.text)
            is DocumentEvent.Message -> message = context.getString(event.text)
        }
    }

    if (doc != null) {
        DocumentContent(
            doc = doc,
            pageFile = { app.store.processedFile(doc.id, it.id) },
            busyMessage = (scanner.busyMessage ?: busy?.message)?.let { stringResource(it) },
            onBack = onBack,
            onOpenPage = { onOpenPage(doc.id, it) },
            onAddPages = scanner.launch,
            onSharePdf = { vm.sharePdf(doc.id) },
            onShareImages = { vm.shareImages(doc.id) },
            onCopyText = { vm.copyAllText(doc.id) },
            onRename = { vm.rename(doc.id, it) },
            onDelete = { vm.delete(doc.id) },
            onMovePage = { from, to -> vm.movePage(doc.id, from, to) },
            onRotatePage = { vm.rotatePage(doc.id, it) },
            onDeletePage = { vm.deletePage(doc.id, it) },
        )
    }

    message?.let {
        MessageDialog(
            it,
            onDismiss = { message = null; offerUpdate = false },
            actionLabel = if (offerUpdate) stringResource(R.string.lib_update_play_services) else null,
            onAction = { openPlayServicesInStore(context) },
        )
    }
}

/** The document UI without the store or view model, so it can be tested with plain data. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DocumentContent(
    doc: ScanDocument,
    pageFile: (ScanPage) -> File,
    busyMessage: String?,
    onBack: () -> Unit,
    onOpenPage: (index: Int) -> Unit,
    onAddPages: () -> Unit,
    onSharePdf: () -> Unit,
    onShareImages: () -> Unit,
    onCopyText: () -> Unit,
    onRename: (String) -> Unit,
    onDelete: () -> Unit,
    onMovePage: (from: Int, to: Int) -> Unit,
    onRotatePage: (pageId: String) -> Unit,
    onDeletePage: (pageId: String) -> Unit,
) {
    var menuOpen by remember { mutableStateOf(false) }
    var renaming by rememberSaveable { mutableStateOf(false) }
    var deletingDoc by rememberSaveable { mutableStateOf(false) }
    var deletingPageId by rememberSaveable { mutableStateOf<String?>(null) }

    Box(Modifier.fillMaxSize()) {
        Scaffold(
            topBar = {
                TopAppBar(
                    navigationIcon = {
                        IconButton(onClick = onBack) {
                            Icon(Icons.AutoMirrored.Filled.ArrowBack, stringResource(R.string.action_back))
                        }
                    },
                    title = { Text(doc.title, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                    actions = {
                        Box {
                            IconButton(onClick = { menuOpen = true }, modifier = Modifier.testTag("documentMenu")) {
                                Icon(Icons.Filled.MoreVert, stringResource(R.string.lib_more_actions))
                            }
                            DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                                MenuItem(Icons.Filled.Edit, R.string.lib_action_rename, "menuRename") { menuOpen = false; renaming = true }
                                MenuItem(Icons.Filled.PhotoLibrary, R.string.lib_doc_share_images, "menuShareImages") { menuOpen = false; onShareImages() }
                                MenuItem(Icons.Filled.ContentCopy, R.string.lib_doc_copy_text, "menuCopyText") { menuOpen = false; onCopyText() }
                                HorizontalDivider()
                                MenuItem(Icons.Outlined.Delete, R.string.lib_doc_delete, "menuDeleteDocument", destructive = true) {
                                    menuOpen = false
                                    deletingDoc = true
                                }
                            }
                        }
                    },
                )
            },
            bottomBar = {
                Surface(tonalElevation = 3.dp) {
                    Row(
                        Modifier.fillMaxWidth().navigationBarsPadding().padding(horizontal = 16.dp, vertical = 12.dp),
                        horizontalArrangement = Arrangement.spacedBy(12.dp),
                    ) {
                        OutlinedButton(
                            onClick = onAddPages,
                            modifier = Modifier.weight(1f).heightIn(min = 64.dp).testTag("addPagesButton"),
                        ) {
                            Icon(Icons.Filled.AddAPhoto, contentDescription = null)
                            Spacer(Modifier.width(8.dp))
                            Text(stringResource(R.string.lib_doc_add_pages), style = MaterialTheme.typography.titleMedium)
                        }
                        Button(
                            onClick = onSharePdf,
                            modifier = Modifier.weight(1f).heightIn(min = 64.dp).testTag("sharePdfButton"),
                        ) {
                            Icon(Icons.Filled.PictureAsPdf, contentDescription = null)
                            Spacer(Modifier.width(8.dp))
                            Text(stringResource(R.string.lib_doc_share_pdf), style = MaterialTheme.typography.titleMedium)
                        }
                    }
                }
            },
        ) { padding ->
            LazyVerticalGrid(
                columns = GridCells.Adaptive(150.dp),
                contentPadding = PaddingValues(16.dp),
                horizontalArrangement = Arrangement.spacedBy(12.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp),
                modifier = Modifier.padding(padding).fillMaxSize().testTag("pageGrid"),
            ) {
                itemsIndexed(doc.pages, key = { _, page -> page.id }) { index, page ->
                    PageCard(
                        page = page,
                        index = index,
                        count = doc.pages.size,
                        file = pageFile(page),
                        onOpen = { onOpenPage(index) },
                        onMove = { step -> PageOrder.target(index, step, doc.pages.size)?.let { onMovePage(index, it) } },
                        onRotate = { onRotatePage(page.id) },
                        onDelete = { deletingPageId = page.id },
                        modifier = Modifier.animateItem(),
                    )
                }
            }
        }
        busyMessage?.let { BusyOverlay(it) }
    }

    if (renaming) {
        RenameDialog(doc.title, onSave = { onRename(it); renaming = false }, onDismiss = { renaming = false })
    }
    if (deletingDoc) {
        ConfirmDeleteDialog(
            title = stringResource(R.string.lib_delete_doc_title),
            message = stringResource(R.string.lib_delete_doc_body, doc.title),
            onConfirm = { deletingDoc = false; onDelete() },
            onDismiss = { deletingDoc = false },
        )
    }
    deletingPageId?.let { pageId ->
        ConfirmDeleteDialog(
            title = stringResource(R.string.lib_delete_page_title),
            message = stringResource(if (doc.pages.size <= 1) R.string.lib_delete_last_page_body else R.string.lib_delete_page_body),
            onConfirm = { deletingPageId = null; onDeletePage(pageId) },
            onDismiss = { deletingPageId = null },
        )
    }
}

@Composable
private fun MenuItem(icon: ImageVector, label: Int, tag: String, destructive: Boolean = false, enabled: Boolean = true, onClick: () -> Unit) {
    val color = if (destructive) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurface
    DropdownMenuItem(
        text = { Text(stringResource(label), color = if (enabled) color else color.copy(alpha = 0.38f)) },
        leadingIcon = { Icon(icon, contentDescription = null, tint = if (enabled) color else color.copy(alpha = 0.38f)) },
        onClick = onClick,
        enabled = enabled,
        modifier = Modifier.heightIn(min = 48.dp).testTag(tag),
    )
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun PageCard(
    page: ScanPage,
    index: Int,
    count: Int,
    file: File,
    onOpen: () -> Unit,
    onMove: (step: Int) -> Unit,
    onRotate: () -> Unit,
    onDelete: () -> Unit,
    modifier: Modifier = Modifier,
) {
    var menuOpen by remember { mutableStateOf(false) }
    val number = index + 1
    val pageLabel = stringResource(R.string.lib_page_number, number)
    Box(modifier) {
        Card(
            colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
            elevation = CardDefaults.cardElevation(defaultElevation = 1.dp),
            modifier = Modifier
                .fillMaxWidth()
                .combinedClickable(
                    onClick = onOpen,
                    onClickLabel = pageLabel,
                    onLongClick = { menuOpen = true },
                    onLongClickLabel = stringResource(R.string.lib_page_actions_for, number),
                )
                .testTag("page-$index"),
        ) {
            Column {
                PageImage(
                    file = file,
                    version = page.version,
                    contentDescription = pageLabel,
                    maxSide = 480,
                    modifier = Modifier
                        .fillMaxWidth()
                        .aspectRatio(3f / 4f)
                        .padding(8.dp)
                        .clip(RoundedCornerShape(4.dp)),
                )
                Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(start = 12.dp)) {
                    Box(
                        Modifier
                            .clip(RoundedCornerShape(50))
                            .background(MaterialTheme.colorScheme.primaryContainer)
                            .padding(horizontal = 10.dp, vertical = 2.dp),
                    ) {
                        Text(
                            number.toString(),
                            style = MaterialTheme.typography.labelLarge,
                            color = MaterialTheme.colorScheme.onPrimaryContainer,
                        )
                    }
                    Spacer(Modifier.weight(1f))
                    IconButton(onClick = { menuOpen = true }, modifier = Modifier.testTag("pageMenu-$index")) {
                        Icon(Icons.Filled.MoreVert, stringResource(R.string.lib_page_actions_for, number))
                    }
                }
            }
        }
        DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
            MenuItem(
                Icons.AutoMirrored.Filled.KeyboardArrowLeft, R.string.lib_page_move_left, "menuMoveLeft",
                enabled = PageOrder.canMoveLeft(index, count),
            ) { menuOpen = false; onMove(-1) }
            MenuItem(
                Icons.AutoMirrored.Filled.KeyboardArrowRight, R.string.lib_page_move_right, "menuMoveRight",
                enabled = PageOrder.canMoveRight(index, count),
            ) { menuOpen = false; onMove(+1) }
            MenuItem(Icons.Filled.Rotate90DegreesCw, R.string.lib_page_rotate, "menuRotate") { menuOpen = false; onRotate() }
            HorizontalDivider()
            MenuItem(Icons.Outlined.Delete, R.string.lib_page_delete, "menuDeletePage", destructive = true) { menuOpen = false; onDelete() }
        }
    }
}
