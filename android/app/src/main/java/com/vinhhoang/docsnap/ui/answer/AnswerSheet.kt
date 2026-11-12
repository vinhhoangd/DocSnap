package com.vinhhoang.docsnap.ui.answer

import android.content.Context
import android.content.Intent
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.ErrorOutline
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Share
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.vinhhoang.docsnap.DocSnapApp
import com.vinhhoang.docsnap.R
import com.vinhhoang.docsnap.answer.AnswerErrors
import com.vinhhoang.docsnap.answer.AnswerEvent
import com.vinhhoang.docsnap.answer.answerModelName
import com.vinhhoang.docsnap.model.PageAnswer
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

/**
 * Sends the page to Claude (through the DocSnap server) and shows the answer as it streams in.
 * Nothing is sent until the button is tapped. A finished answer is saved for the page's current version.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AnswerSheet(documentId: String, pageId: String, onDismiss: () -> Unit) {
    val context = LocalContext.current
    val app = context.applicationContext as DocSnapApp
    val documents by app.store.documents.collectAsStateWithLifecycle()
    val page = documents.firstOrNull { it.id == documentId }?.pages?.firstOrNull { it.id == pageId }
    val selectedModel by app.settings.answerModel.collectAsStateWithLifecycle()

    var state by remember(documentId, pageId) { mutableStateOf(AnswerUiState.initial(page?.answer, page?.version)) }
    var job by remember { mutableStateOf<Job?>(null) }
    var copied by remember { mutableStateOf(false) }
    // Cancelled when the sheet leaves the screen, which cancels the HTTP call too.
    val scope = rememberCoroutineScope()
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val clipboard = LocalClipboardManager.current
    val hasOcr = !page?.recognizedText.isNullOrBlank()

    fun start() {
        job?.cancel()
        copied = false
        val current = page
        if (current == null) {
            state = AnswerUiState(phase = AnswerPhase.Failed, errorCode = AnswerErrors.IMAGE_UNAVAILABLE)
            return
        }
        val model = selectedModel.id
        val version = current.version
        val image = app.store.processedFile(documentId, current.id)
        val ocr = current.recognizedText?.takeIf { it.isNotBlank() }
        state = AnswerUiState.started(model)
        job = scope.launch {
            app.answers.answer(image, ocr, model).collect { event ->
                state = state.reduce(event)
                if (event is AnswerEvent.Done && state.phase == AnswerPhase.Finished) {
                    val answer = PageAnswer(state.text, state.model, System.currentTimeMillis(), version)
                    // App scope: closing the sheet right after "done" must not lose the save.
                    app.appScope.launch { runCatching { app.store.setAnswer(documentId, pageId, answer) } }
                }
            }
            state = state.ended()
        }
    }

    fun stop() {
        job?.cancel()
        job = null
        state = state.stopped()
    }

    fun close() {
        job?.cancel()
        scope.launch { sheetState.hide() }.invokeOnCompletion { onDismiss() }
    }

    ModalBottomSheet(
        onDismissRequest = {
            job?.cancel()
            onDismiss()
        },
        sheetState = sheetState,
    ) {
        Column(
            Modifier
                .fillMaxWidth()
                .padding(horizontal = 20.dp)
                .padding(bottom = 16.dp),
        ) {
            Header(state = state, selectedModelName = answerModelName(selectedModel.id), onClose = ::close)
            Spacer(Modifier.size(12.dp))
            Column(
                Modifier
                    .weight(1f, fill = false)
                    .verticalScroll(rememberScrollState()),
            ) {
                Body(state = state, hasOcr = hasOcr)
            }
            Spacer(Modifier.size(16.dp))
            Actions(
                state = state,
                copied = copied,
                onStart = ::start,
                onStop = ::stop,
                onCopy = {
                    clipboard.setText(AnnotatedString(AnswerMarkdown.plainText(state.text)))
                    copied = true
                },
                onShare = { shareText(context, AnswerMarkdown.plainText(state.text)) },
            )
        }
    }
}

@Composable
private fun Header(state: AnswerUiState, selectedModelName: String, onClose: () -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Surface(shape = MaterialTheme.shapes.medium, color = MaterialTheme.colorScheme.primaryContainer) {
            Icon(
                Icons.Filled.AutoAwesome,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onPrimaryContainer,
                modifier = Modifier.padding(8.dp).size(24.dp),
            )
        }
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(
                stringResource(R.string.answer_title),
                style = MaterialTheme.typography.titleLarge,
                modifier = Modifier.semantics { heading() },
            )
            val modelName = if (state.model.isBlank()) selectedModelName else answerModelName(state.model)
            Text(
                when (state.phase) {
                    AnswerPhase.Finished, AnswerPhase.Stopped -> stringResource(R.string.answer_model_by, modelName)
                    AnswerPhase.Waiting, AnswerPhase.Streaming -> modelName
                    else -> stringResource(R.string.answer_model_will_use, modelName)
                },
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        IconButton(onClick = onClose) {
            Icon(Icons.Filled.Close, contentDescription = stringResource(R.string.answer_close))
        }
    }
}

@Composable
private fun Body(state: AnswerUiState, hasOcr: Boolean) {
    when (state.phase) {
        AnswerPhase.Idle -> {
            Text(stringResource(R.string.answer_intro), style = MaterialTheme.typography.bodyLarge)
            Spacer(Modifier.size(12.dp))
            Notice(Icons.Filled.Lock) {
                Text(stringResource(R.string.answer_privacy), style = MaterialTheme.typography.bodyMedium)
                if (hasOcr) {
                    Spacer(Modifier.size(4.dp))
                    Text(stringResource(R.string.answer_privacy_ocr), style = MaterialTheme.typography.bodyMedium)
                }
            }
        }
        AnswerPhase.Waiting -> Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.padding(vertical = 24.dp),
        ) {
            CircularProgressIndicator(Modifier.size(32.dp))
            Spacer(Modifier.width(16.dp))
            Column {
                Text(stringResource(R.string.answer_waiting_title), style = MaterialTheme.typography.titleMedium)
                Text(
                    stringResource(R.string.answer_waiting_body),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
        AnswerPhase.Streaming -> {
            MarkdownText(state.text)
            Spacer(Modifier.size(12.dp))
            LinearProgressIndicator(Modifier.fillMaxWidth())
        }
        AnswerPhase.Finished -> {
            MarkdownText(state.text)
            Spacer(Modifier.size(16.dp))
            if (state.truncated) {
                Note(Icons.Filled.Info, stringResource(R.string.answer_truncated))
                Spacer(Modifier.size(4.dp))
            }
            Note(Icons.Filled.Info, stringResource(R.string.answer_disclaimer))
        }
        AnswerPhase.Stopped -> {
            MarkdownText(state.text)
            Spacer(Modifier.size(16.dp))
            Note(Icons.Filled.Stop, stringResource(R.string.answer_stopped))
        }
        AnswerPhase.Failed -> Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            modifier = Modifier.fillMaxWidth().padding(vertical = 24.dp),
        ) {
            Icon(
                Icons.Filled.ErrorOutline,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.error,
                modifier = Modifier.size(40.dp),
            )
            Spacer(Modifier.size(8.dp))
            Text(stringResource(R.string.answer_error_title), style = MaterialTheme.typography.titleMedium)
            Spacer(Modifier.size(4.dp))
            Text(
                stringResource(answerErrorMessage(state.errorCode)),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center,
            )
        }
    }
}

@Composable
private fun Actions(
    state: AnswerUiState,
    copied: Boolean,
    onStart: () -> Unit,
    onStop: () -> Unit,
    onCopy: () -> Unit,
    onShare: () -> Unit,
) {
    val tall = Modifier.fillMaxWidth().heightIn(min = 52.dp)
    when (state.phase) {
        AnswerPhase.Idle -> Button(onClick = onStart, modifier = tall) {
            Icon(Icons.AutoMirrored.Filled.Send, contentDescription = null, modifier = Modifier.size(20.dp))
            Spacer(Modifier.width(8.dp))
            Text(stringResource(R.string.answer_start))
        }
        AnswerPhase.Waiting, AnswerPhase.Streaming -> OutlinedButton(onClick = onStop, modifier = tall) {
            Icon(Icons.Filled.Stop, contentDescription = null, modifier = Modifier.size(20.dp))
            Spacer(Modifier.width(8.dp))
            Text(stringResource(R.string.answer_stop))
        }
        AnswerPhase.Finished -> Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth()) {
            SheetAction(
                if (copied) Icons.Filled.Check else Icons.Filled.ContentCopy,
                stringResource(if (copied) R.string.answer_copied else R.string.answer_copy),
                onCopy,
                Modifier.weight(1f),
            )
            SheetAction(Icons.Filled.Share, stringResource(R.string.answer_share), onShare, Modifier.weight(1f))
            SheetAction(Icons.Filled.Refresh, stringResource(R.string.answer_ask_again), onStart, Modifier.weight(1f))
        }
        AnswerPhase.Stopped -> FilledTonalButton(onClick = onStart, modifier = tall) {
            Icon(Icons.Filled.Refresh, contentDescription = null, modifier = Modifier.size(20.dp))
            Spacer(Modifier.width(8.dp))
            Text(stringResource(R.string.answer_ask_again))
        }
        AnswerPhase.Failed -> Button(onClick = onStart, modifier = tall) {
            Icon(Icons.Filled.Refresh, contentDescription = null, modifier = Modifier.size(20.dp))
            Spacer(Modifier.width(8.dp))
            Text(stringResource(R.string.answer_retry))
        }
    }
}

/** Icon above a short label: fits three in a row even with longer Vietnamese labels. */
@Composable
private fun SheetAction(icon: ImageVector, label: String, onClick: () -> Unit, modifier: Modifier = Modifier) {
    Surface(
        onClick = onClick,
        shape = MaterialTheme.shapes.large,
        color = MaterialTheme.colorScheme.secondaryContainer,
        contentColor = MaterialTheme.colorScheme.onSecondaryContainer,
        modifier = modifier.heightIn(min = 64.dp),
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
            modifier = Modifier.padding(vertical = 10.dp, horizontal = 4.dp),
        ) {
            Icon(icon, contentDescription = null, modifier = Modifier.size(22.dp))
            Spacer(Modifier.size(4.dp))
            Text(label, style = MaterialTheme.typography.labelLarge, maxLines = 1, textAlign = TextAlign.Center)
        }
    }
}

@Composable
private fun Notice(icon: ImageVector, content: @Composable () -> Unit) {
    Surface(shape = MaterialTheme.shapes.medium, color = MaterialTheme.colorScheme.surfaceVariant) {
        Row(Modifier.padding(12.dp)) {
            Icon(icon, contentDescription = null, modifier = Modifier.size(20.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
            Spacer(Modifier.width(10.dp))
            Column(Modifier.weight(1f)) { content() }
        }
    }
}

@Composable
private fun Note(icon: ImageVector, text: String) {
    Row(verticalAlignment = Alignment.Top) {
        Icon(icon, contentDescription = null, modifier = Modifier.size(16.dp).padding(top = 2.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
        Spacer(Modifier.width(6.dp))
        Text(text, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

/** Renders [AnswerMarkdown] blocks; the whole answer is selectable. */
@Composable
fun MarkdownText(source: String, modifier: Modifier = Modifier) {
    val blocks = remember(source) { AnswerMarkdown.parse(source) }
    val body = MaterialTheme.typography.bodyLarge
    val muted = MaterialTheme.colorScheme.onSurfaceVariant
    SelectionContainer(modifier.fillMaxWidth()) {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            for (block in blocks) {
                when (block) {
                    is MdBlock.Heading -> Text(
                        AnswerMarkdown.inline(block.text),
                        style = if (block.level <= 2) MaterialTheme.typography.titleLarge else MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.SemiBold,
                        modifier = Modifier.padding(top = 8.dp).semantics { heading() },
                    )
                    is MdBlock.Bullet -> Row(Modifier.padding(start = (16 * block.indent).dp)) {
                        Text("•", style = body, color = muted, modifier = Modifier.width(20.dp))
                        Text(AnswerMarkdown.inline(block.text), style = body)
                    }
                    is MdBlock.Numbered -> Row(Modifier.padding(start = (16 * block.indent).dp)) {
                        Text("${block.number}.", style = body, color = muted, modifier = Modifier.widthIn(min = 24.dp).padding(end = 6.dp))
                        Text(AnswerMarkdown.inline(block.text), style = body)
                    }
                    is MdBlock.Paragraph -> Text(AnswerMarkdown.inline(block.text), style = body)
                }
            }
        }
    }
}

private fun shareText(context: Context, text: String) {
    val send = Intent(Intent.ACTION_SEND).apply {
        type = "text/plain"
        putExtra(Intent.EXTRA_TEXT, text)
    }
    val chooser = Intent.createChooser(send, null).apply {
        if (context !is android.app.Activity) addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    }
    runCatching { context.startActivity(chooser) }
}
