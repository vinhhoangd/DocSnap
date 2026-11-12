package com.vinhhoang.docsnap.ui.library

import android.text.format.DateUtils
import androidx.compose.foundation.ExperimentalFoundationApi
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
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ViewList
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.DocumentScanner
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.GridView
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExtendedFloatingActionButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.vinhhoang.docsnap.DocSnapApp
import com.vinhhoang.docsnap.R
import com.vinhhoang.docsnap.data.LibraryLayout
import com.vinhhoang.docsnap.model.ScanDocument
import androidx.lifecycle.Lifecycle
import com.vinhhoang.docsnap.scan.openPlayServicesInStore
import com.vinhhoang.docsnap.scan.rememberScanner
import com.vinhhoang.docsnap.ui.common.BusyOverlay
import com.vinhhoang.docsnap.ui.common.CollectEvents
import com.vinhhoang.docsnap.ui.common.ConfirmDeleteDialog
import com.vinhhoang.docsnap.ui.common.DateSection
import com.vinhhoang.docsnap.ui.common.DateSections
import com.vinhhoang.docsnap.ui.common.MessageDialog
import com.vinhhoang.docsnap.ui.common.PageImage
import com.vinhhoang.docsnap.ui.common.RenameDialog
import com.vinhhoang.docsnap.ui.common.SearchText
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.time.Instant
import java.time.ZoneId

@Composable
fun LibraryScreen(onOpenDocument: (String) -> Unit, onOpenSettings: () -> Unit) {
    val context = LocalContext.current
    val app = context.applicationContext as DocSnapApp
    val vm: LibraryViewModel = viewModel()
    val documents by app.store.documents.collectAsStateWithLifecycle()
    val loaded by app.store.loaded.collectAsStateWithLifecycle()
    val layout by app.settings.libraryLayout.collectAsStateWithLifecycle()
    val saving by vm.busy.collectAsStateWithLifecycle()
    var message by rememberSaveable { mutableStateOf<String?>(null) }
    // The message is a scanner error that the Play Store can fix ("Update" button).
    var offerUpdate by rememberSaveable { mutableStateOf(false) }

    val scanner = rememberScanner(
        onPages = { vm.saveScan(it) },
        onError = {
            message = context.getString(it.message)
            offerUpdate = it.offersPlayServicesUpdate
        },
    )

    // RESUMED: opening the new document is a navigation, which only the resumed screen may do.
    CollectEvents(vm.events, Lifecycle.State.RESUMED) { event ->
        when (event) {
            is LibraryEvent.OpenDocument -> onOpenDocument(event.id)
            LibraryEvent.SaveFailed -> {
                message = context.getString(R.string.lib_error_save_scan)
                offerUpdate = false
            }
            LibraryEvent.ChangeFailed -> {
                message = context.getString(R.string.error_generic)
                offerUpdate = false
            }
        }
    }

    LibraryContent(
        documents = documents,
        loaded = loaded,
        layout = layout,
        thumbnail = { doc -> doc.pages.firstOrNull()?.let { app.store.processedFile(doc.id, it.id) to it.version } },
        busyMessage = when {
            saving -> R.string.lib_saving
            else -> scanner.busyMessage
        }?.let { stringResource(it) },
        onToggleLayout = {
            app.settings.setLibraryLayout(if (layout == LibraryLayout.Grid) LibraryLayout.List else LibraryLayout.Grid)
        },
        onScan = scanner.launch,
        onOpen = onOpenDocument,
        onRename = vm::rename,
        onDelete = vm::delete,
        onOpenSettings = onOpenSettings,
    )

    message?.let {
        MessageDialog(
            it,
            onDismiss = { message = null; offerUpdate = false },
            actionLabel = if (offerUpdate) stringResource(R.string.lib_update_play_services) else null,
            onAction = { openPlayServicesInStore(context) },
        )
    }
}

/**
 * The library UI without the store, so it can be tested with plain data. Rename/delete dialogs live
 * here; `onRename` / `onDelete` run only after the user confirms.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LibraryContent(
    documents: List<ScanDocument>,
    layout: LibraryLayout,
    thumbnail: (ScanDocument) -> Pair<File, Int>?,
    busyMessage: String?,
    onToggleLayout: () -> Unit,
    onScan: () -> Unit,
    onOpen: (String) -> Unit,
    onRename: (id: String, title: String) -> Unit,
    onDelete: (id: String) -> Unit,
    onOpenSettings: () -> Unit,
    now: Long = System.currentTimeMillis(),
    zone: ZoneId = ZoneId.systemDefault(),
    loaded: Boolean = true,
) {
    var query by rememberSaveable { mutableStateOf("") }
    var renamingId by rememberSaveable { mutableStateOf<String?>(null) }
    var deletingId by rememberSaveable { mutableStateOf<String?>(null) }

    // Folded title + OCR text per document, built off the main thread (OCR text can be long).
    val index by produceState(emptyMap<String, String>(), documents) {
        value = withContext(Dispatchers.Default) {
            documents.associate { it.id to SearchText.fold(it.title + "\n" + it.allText) }
        }
    }
    val terms = SearchText.terms(query)
    val visible = if (terms.isEmpty()) documents else documents.filter { doc ->
        index[doc.id]?.let { SearchText.matchesFolded(terms, it) } ?: SearchText.matches(query, doc.title)
    }
    val sections = DateSections.group(visible, now, zone) { it.updatedAt }

    Box(Modifier.fillMaxSize()) {
        Scaffold(
            topBar = {
                TopAppBar(
                    title = {
                        Text(
                            stringResource(R.string.lib_title),
                            style = MaterialTheme.typography.headlineMedium,
                            modifier = Modifier.semantics { heading() },
                        )
                    },
                    actions = {
                        if (documents.isNotEmpty()) {
                            IconButton(onClick = onToggleLayout, modifier = Modifier.testTag("layoutToggle")) {
                                if (layout == LibraryLayout.Grid) {
                                    Icon(Icons.AutoMirrored.Filled.ViewList, stringResource(R.string.lib_view_list))
                                } else {
                                    Icon(Icons.Filled.GridView, stringResource(R.string.lib_view_grid))
                                }
                            }
                        }
                        IconButton(onClick = onOpenSettings, modifier = Modifier.testTag("settingsButton")) {
                            Icon(Icons.Filled.Settings, stringResource(R.string.lib_settings))
                        }
                    },
                )
            },
            floatingActionButton = {
                if (documents.isNotEmpty()) {
                    ExtendedFloatingActionButton(
                        onClick = onScan,
                        icon = { Icon(Icons.Filled.DocumentScanner, contentDescription = null, modifier = Modifier.size(28.dp)) },
                        text = { Text(stringResource(R.string.lib_scan), style = MaterialTheme.typography.titleLarge) },
                        modifier = Modifier.heightIn(min = 64.dp).testTag("scanFab"),
                    )
                }
            },
        ) { padding ->
            if (!loaded) {
                // Cold start: the documents are still being read. Not "no documents yet".
                LoadingLibrary(Modifier.padding(padding))
            } else if (documents.isEmpty()) {
                EmptyLibrary(onScan, Modifier.padding(padding))
            } else {
                Column(Modifier.padding(padding).fillMaxSize()) {
                    SearchField(query, onQueryChange = { query = it })
                    if (visible.isEmpty()) {
                        Text(
                            stringResource(R.string.lib_no_results, query.trim()),
                            style = MaterialTheme.typography.bodyLarge,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.padding(24.dp).testTag("noResults"),
                        )
                    } else {
                        DocumentGrid(
                            sections = sections,
                            layout = layout,
                            thumbnail = thumbnail,
                            now = now,
                            zone = zone,
                            onOpen = onOpen,
                            onRename = { renamingId = it },
                            onDelete = { deletingId = it },
                        )
                    }
                }
            }
        }
        busyMessage?.let { BusyOverlay(it) }
    }

    // A dialog for a document that was deleted meanwhile simply isn't shown.
    documents.firstOrNull { it.id == renamingId }?.let { doc ->
        RenameDialog(
            currentTitle = doc.title,
            onSave = { onRename(doc.id, it); renamingId = null },
            onDismiss = { renamingId = null },
        )
    }
    documents.firstOrNull { it.id == deletingId }?.let { doc ->
        ConfirmDeleteDialog(
            title = stringResource(R.string.lib_delete_doc_title),
            message = stringResource(R.string.lib_delete_doc_body, doc.title),
            onConfirm = { onDelete(doc.id); deletingId = null },
            onDismiss = { deletingId = null },
        )
    }
}

@Composable
private fun SearchField(query: String, onQueryChange: (String) -> Unit) {
    OutlinedTextField(
        value = query,
        onValueChange = onQueryChange,
        placeholder = { Text(stringResource(R.string.lib_search_hint)) },
        leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null) },
        trailingIcon = {
            if (query.isNotEmpty()) {
                IconButton(onClick = { onQueryChange("") }) {
                    Icon(Icons.Filled.Close, stringResource(R.string.lib_search_clear))
                }
            }
        },
        singleLine = true,
        shape = RoundedCornerShape(28.dp),
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 4.dp)
            .testTag("searchField"),
    )
}

@Composable
private fun LoadingLibrary(modifier: Modifier = Modifier) {
    val description = stringResource(R.string.lib_loading)
    Box(
        modifier
            .fillMaxSize()
            .semantics { contentDescription = description }
            .testTag("libraryLoading"),
        contentAlignment = Alignment.Center,
    ) {
        CircularProgressIndicator()
    }
}

@Composable
private fun EmptyLibrary(onScan: () -> Unit, modifier: Modifier = Modifier) {
    Column(
        modifier.fillMaxSize().padding(32.dp).testTag("emptyLibrary"),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Icon(
            Icons.Outlined.Description,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.primary,
            modifier = Modifier.size(96.dp),
        )
        Spacer(Modifier.height(24.dp))
        Text(stringResource(R.string.lib_empty_title), style = MaterialTheme.typography.headlineSmall)
        Spacer(Modifier.height(8.dp))
        Text(
            stringResource(R.string.lib_empty_body),
            style = MaterialTheme.typography.bodyLarge,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(Modifier.height(32.dp))
        Button(
            onClick = onScan,
            contentPadding = PaddingValues(horizontal = 32.dp, vertical = 16.dp),
            modifier = Modifier.heightIn(min = 64.dp).testTag("emptyScanButton"),
        ) {
            Icon(Icons.Filled.DocumentScanner, contentDescription = null, modifier = Modifier.size(28.dp))
            Spacer(Modifier.width(12.dp))
            Text(stringResource(R.string.lib_scan), style = MaterialTheme.typography.titleLarge)
        }
    }
}

@Composable
private fun DocumentGrid(
    sections: List<Pair<DateSection, List<ScanDocument>>>,
    layout: LibraryLayout,
    thumbnail: (ScanDocument) -> Pair<File, Int>?,
    now: Long,
    zone: ZoneId,
    onOpen: (String) -> Unit,
    onRename: (String) -> Unit,
    onDelete: (String) -> Unit,
) {
    val grid = layout == LibraryLayout.Grid
    LazyVerticalGrid(
        columns = if (grid) GridCells.Adaptive(150.dp) else GridCells.Fixed(1),
        contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 112.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalArrangement = Arrangement.spacedBy(if (grid) 16.dp else 8.dp),
        modifier = Modifier.fillMaxSize().testTag("documentGrid"),
    ) {
        sections.forEach { (section, docs) ->
            item(key = "header-$section", span = { GridItemSpan(maxLineSpan) }) {
                SectionHeader(sectionTitle(section, now, zone))
            }
            items(docs, key = { it.id }) { doc ->
                DocumentItem(
                    doc = doc,
                    grid = grid,
                    thumbnail = thumbnail(doc),
                    now = now,
                    onOpen = { onOpen(doc.id) },
                    onRename = { onRename(doc.id) },
                    onDelete = { onDelete(doc.id) },
                )
            }
        }
    }
}

@Composable
private fun sectionTitle(section: DateSection, now: Long, zone: ZoneId): String = when (section) {
    DateSection.Today -> stringResource(R.string.lib_section_today)
    DateSection.Yesterday -> stringResource(R.string.lib_section_yesterday)
    DateSection.Previous7Days -> stringResource(R.string.lib_section_previous_7_days)
    is DateSection.Month -> {
        val locale = LocalConfiguration.current.locales[0]
        val year = Instant.ofEpochMilli(now).atZone(zone).year
        DateSections.monthTitle(section, year, locale)
    }
}

@Composable
private fun SectionHeader(title: String) {
    Text(
        title,
        style = MaterialTheme.typography.titleMedium,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.padding(top = 12.dp, bottom = 4.dp).semantics { heading() },
    )
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun DocumentItem(
    doc: ScanDocument,
    grid: Boolean,
    thumbnail: Pair<File, Int>?,
    now: Long,
    onOpen: () -> Unit,
    onRename: () -> Unit,
    onDelete: () -> Unit,
) {
    var menuOpen by remember { mutableStateOf(false) }
    val subtitle = pluralStringResource(R.plurals.lib_page_count, doc.pages.size, doc.pages.size) +
        " · " + formatDate(doc.updatedAt, now)

    Box {
        Card(
            colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
            elevation = CardDefaults.cardElevation(defaultElevation = 1.dp),
            modifier = Modifier
                .fillMaxWidth()
                .combinedClickable(
                    onClick = onOpen,
                    onLongClick = { menuOpen = true },
                    onLongClickLabel = stringResource(R.string.lib_more_actions),
                )
                .testTag("document-${doc.id}"),
        ) {
            if (grid) {
                Column {
                    Thumbnail(thumbnail, Modifier.fillMaxWidth().aspectRatio(3f / 4f))
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f).padding(start = 12.dp, top = 8.dp, bottom = 8.dp)) {
                            Text(doc.title, style = MaterialTheme.typography.titleSmall, maxLines = 2, overflow = TextOverflow.Ellipsis)
                            Text(subtitle, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1)
                        }
                        MoreButton(doc.title) { menuOpen = true }
                    }
                }
            } else {
                Row(Modifier.padding(8.dp), verticalAlignment = Alignment.CenterVertically) {
                    Thumbnail(thumbnail, Modifier.width(60.dp).aspectRatio(3f / 4f))
                    Column(Modifier.weight(1f).padding(horizontal = 12.dp)) {
                        Text(doc.title, style = MaterialTheme.typography.titleMedium, maxLines = 2, overflow = TextOverflow.Ellipsis)
                        Text(subtitle, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1)
                    }
                    MoreButton(doc.title) { menuOpen = true }
                }
            }
        }
        DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
            DropdownMenuItem(
                text = { Text(stringResource(R.string.lib_action_rename)) },
                leadingIcon = { Icon(Icons.Filled.Edit, contentDescription = null) },
                onClick = { menuOpen = false; onRename() },
                modifier = Modifier.testTag("menuRename"),
            )
            DropdownMenuItem(
                text = { Text(stringResource(R.string.action_delete), color = MaterialTheme.colorScheme.error) },
                leadingIcon = { Icon(Icons.Outlined.Delete, contentDescription = null, tint = MaterialTheme.colorScheme.error) },
                onClick = { menuOpen = false; onDelete() },
                modifier = Modifier.testTag("menuDelete"),
            )
        }
    }
}

@Composable
private fun MoreButton(title: String, onClick: () -> Unit) {
    IconButton(onClick = onClick) {
        Icon(Icons.Filled.MoreVert, contentDescription = stringResource(R.string.lib_more_actions_for, title))
    }
}

@Composable
private fun Thumbnail(thumbnail: Pair<File, Int>?, modifier: Modifier) {
    val clipped = modifier.clip(RoundedCornerShape(8.dp))
    if (thumbnail == null) {
        Box(clipped)
    } else {
        PageImage(file = thumbnail.first, version = thumbnail.second, contentDescription = null, maxSide = 480, modifier = clipped)
    }
}

@Composable
private fun formatDate(time: Long, now: Long): String {
    val context = LocalContext.current
    val zone = ZoneId.systemDefault()
    val sameDay = Instant.ofEpochMilli(time).atZone(zone).toLocalDate() == Instant.ofEpochMilli(now).atZone(zone).toLocalDate()
    val flags = if (sameDay) DateUtils.FORMAT_SHOW_TIME else DateUtils.FORMAT_SHOW_DATE or DateUtils.FORMAT_ABBREV_MONTH
    return DateUtils.formatDateTime(context, time, flags)
}
