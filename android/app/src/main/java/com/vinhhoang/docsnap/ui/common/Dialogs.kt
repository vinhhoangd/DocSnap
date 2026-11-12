package com.vinhhoang.docsnap.ui.common

import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.TextFieldValue
import com.vinhhoang.docsnap.R

/** Rename dialog with the current name selected, so typing replaces it. Save is off for blank names. */
@Composable
fun RenameDialog(currentTitle: String, onSave: (String) -> Unit, onDismiss: () -> Unit) {
    var value by rememberSaveable(currentTitle, stateSaver = TextFieldValue.Saver) {
        mutableStateOf(TextFieldValue(currentTitle, TextRange(0, currentTitle.length)))
    }
    val focus = remember { FocusRequester() }
    val canSave = value.text.isNotBlank()
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.lib_rename_title)) },
        text = {
            OutlinedTextField(
                value = value,
                onValueChange = { value = it },
                label = { Text(stringResource(R.string.lib_rename_label)) },
                singleLine = true,
                keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences, imeAction = ImeAction.Done),
                keyboardActions = KeyboardActions(onDone = { if (canSave) onSave(value.text.trim()) }),
                modifier = Modifier.focusRequester(focus).testTag("renameField"),
            )
        },
        confirmButton = {
            TextButton(onClick = { onSave(value.text.trim()) }, enabled = canSave, modifier = Modifier.testTag("renameSave")) {
                Text(stringResource(R.string.lib_action_save))
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text(stringResource(R.string.action_cancel)) }
        },
    )
    LaunchedEffect(Unit) { runCatching { focus.requestFocus() } }
}

/** A destructive yes/no question ("Xóa trang này?"). */
@Composable
fun ConfirmDeleteDialog(title: String, message: String, onConfirm: () -> Unit, onDismiss: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = { Text(message) },
        confirmButton = {
            TextButton(
                onClick = onConfirm,
                colors = ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.error),
                modifier = Modifier.testTag("confirmDelete"),
            ) { Text(stringResource(R.string.action_delete)) }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text(stringResource(R.string.action_cancel)) }
        },
    )
}

/**
 * A simple message with an OK button. With `actionLabel`, a second button does something about it
 * (e.g. "Update" opens the Play Store) and then closes the dialog.
 */
@Composable
fun MessageDialog(message: String, onDismiss: () -> Unit, actionLabel: String? = null, onAction: () -> Unit = {}) {
    AlertDialog(
        onDismissRequest = onDismiss,
        text = { Text(message, style = MaterialTheme.typography.bodyLarge) },
        confirmButton = {
            if (actionLabel != null) {
                TextButton(onClick = { onAction(); onDismiss() }, modifier = Modifier.testTag("messageAction")) { Text(actionLabel) }
            } else {
                TextButton(onClick = onDismiss) { Text(stringResource(R.string.action_ok)) }
            }
        },
        dismissButton = if (actionLabel != null) {
            { TextButton(onClick = onDismiss) { Text(stringResource(R.string.lib_not_now)) } }
        } else {
            null
        },
    )
}
