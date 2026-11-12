package com.vinhhoang.docsnap.ui.settings

import android.app.LocaleManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import androidx.annotation.StringRes
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.OpenInNew
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.CloudOff
import androidx.compose.material.icons.filled.DarkMode
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.Dns
import androidx.compose.material.icons.filled.FilterBAndW
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Language
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.rememberTopAppBarState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.vinhhoang.docsnap.BuildConfig
import com.vinhhoang.docsnap.DocSnapApp
import com.vinhhoang.docsnap.R
import com.vinhhoang.docsnap.answer.displayName
import com.vinhhoang.docsnap.data.AnswerModel
import com.vinhhoang.docsnap.data.Appearance
import com.vinhhoang.docsnap.export.PdfPageSize
import com.vinhhoang.docsnap.model.ScanFilter

private enum class ServerStatus { Checking, Connected, NotSetUp, Unreachable }

private enum class Picker { Appearance, Filter, Model, PageSize }

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(onBack: () -> Unit) {
    val context = LocalContext.current
    val app = context.applicationContext as DocSnapApp
    val settings = app.settings
    val appearance by settings.appearance.collectAsStateWithLifecycle()
    val filter by settings.defaultFilter.collectAsStateWithLifecycle()
    val model by settings.answerModel.collectAsStateWithLifecycle()
    val pageSize by settings.pdfPageSize.collectAsStateWithLifecycle()

    var picker by remember { mutableStateOf<Picker?>(null) }
    var serverStatus by remember { mutableStateOf(ServerStatus.Checking) }
    var serverCheck by remember { mutableIntStateOf(0) }
    LaunchedEffect(serverCheck) {
        if (!app.answers.isConfigured) {
            serverStatus = ServerStatus.NotSetUp
            return@LaunchedEffect
        }
        serverStatus = ServerStatus.Checking
        serverStatus = if (app.answers.health()) ServerStatus.Connected else ServerStatus.Unreachable
    }

    val scrollBehavior = TopAppBarDefaults.pinnedScrollBehavior(rememberTopAppBarState())
    Scaffold(
        modifier = Modifier.nestedScroll(scrollBehavior.nestedScrollConnection),
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.settings_title)) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = stringResource(R.string.action_back))
                    }
                },
                scrollBehavior = scrollBehavior,
            )
        },
    ) { padding ->
        LazyColumn(contentPadding = padding, modifier = Modifier.fillMaxWidth()) {
            item { SectionHeader(R.string.settings_section_display) }
            item {
                SettingRow(
                    icon = Icons.Filled.DarkMode,
                    title = stringResource(R.string.settings_appearance),
                    value = stringResource(appearance.label),
                    onClick = { picker = Picker.Appearance },
                )
            }

            item { SectionHeader(R.string.settings_section_language) }
            item { LanguageRow(context) }

            item { SectionHeader(R.string.settings_section_scanning) }
            item {
                SettingRow(
                    icon = Icons.Filled.FilterBAndW,
                    title = stringResource(R.string.settings_default_filter),
                    value = stringResource(filter.label),
                    onClick = { picker = Picker.Filter },
                )
            }
            item { Footer(stringResource(R.string.settings_default_filter_footer)) }

            item { SectionHeader(R.string.settings_section_answers) }
            item {
                SettingRow(
                    icon = Icons.Filled.AutoAwesome,
                    title = stringResource(R.string.settings_model),
                    value = model.displayName + " · " + stringResource(model.detail),
                    onClick = { picker = Picker.Model },
                )
            }
            item {
                ServerRow(serverStatus, onRetry = { serverCheck++ })
            }
            item { Footer(stringResource(R.string.settings_answers_footer)) }

            item { SectionHeader(R.string.settings_section_pdf) }
            item {
                SettingRow(
                    icon = Icons.Filled.Description,
                    title = stringResource(R.string.settings_page_size),
                    value = stringResource(pageSize.label),
                    onClick = { picker = Picker.PageSize },
                )
            }

            item { SectionHeader(R.string.settings_section_about) }
            item {
                SettingRow(
                    icon = Icons.Filled.Info,
                    title = stringResource(R.string.settings_version),
                    value = "${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})",
                )
            }
            item {
                Row(Modifier.padding(horizontal = 16.dp, vertical = 12.dp), verticalAlignment = Alignment.Top) {
                    Icon(
                        Icons.Filled.Lock,
                        contentDescription = null,
                        modifier = Modifier.size(16.dp).padding(top = 2.dp),
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Spacer(Modifier.width(8.dp))
                    Text(
                        stringResource(R.string.settings_privacy_footer),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }
    }

    when (picker) {
        Picker.Appearance -> ChoiceDialog(
            title = stringResource(R.string.settings_appearance),
            options = Appearance.entries,
            selected = appearance,
            label = { stringResource(it.label) },
            onSelect = settings::setAppearance,
            onDismiss = { picker = null },
        )
        Picker.Filter -> ChoiceDialog(
            title = stringResource(R.string.settings_default_filter),
            options = ScanFilter.entries,
            selected = filter,
            label = { stringResource(it.label) },
            onSelect = settings::setDefaultFilter,
            onDismiss = { picker = null },
        )
        Picker.Model -> ChoiceDialog(
            title = stringResource(R.string.settings_model),
            options = AnswerModel.entries,
            selected = model,
            label = { it.displayName },
            detail = { stringResource(it.detail) },
            onSelect = settings::setAnswerModel,
            onDismiss = { picker = null },
        )
        Picker.PageSize -> ChoiceDialog(
            title = stringResource(R.string.settings_page_size),
            options = PdfPageSize.entries,
            selected = pageSize,
            label = { stringResource(it.label) },
            onSelect = settings::setPdfPageSize,
            onDismiss = { picker = null },
        )
        null -> Unit
    }
}

@Composable
private fun LanguageRow(context: Context) {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
        // Re-read on every composition: changing the app language recreates the activity.
        val appLocales = remember(LocalConfiguration.current) {
            context.getSystemService(LocaleManager::class.java)?.applicationLocales
        }
        val value = if (appLocales == null || appLocales.isEmpty) {
            stringResource(R.string.settings_language_system)
        } else {
            appLocales[0].let { it.getDisplayName(it).replaceFirstChar { c -> c.titlecase(it) } }
        }
        SettingRow(
            icon = Icons.Filled.Language,
            title = stringResource(R.string.settings_language),
            value = value,
            trailing = {
                Icon(
                    Icons.AutoMirrored.Filled.OpenInNew,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            },
            onClick = {
                val intent = Intent(
                    android.provider.Settings.ACTION_APP_LOCALE_SETTINGS,
                    Uri.fromParts("package", context.packageName, null),
                )
                runCatching { context.startActivity(intent) }
            },
        )
    } else {
        SettingRow(
            icon = Icons.Filled.Language,
            title = stringResource(R.string.settings_language),
            value = stringResource(R.string.settings_language_follows_phone),
        )
    }
}

@Composable
private fun ServerRow(status: ServerStatus, onRetry: () -> Unit) {
    val (text, color) = when (status) {
        ServerStatus.Checking -> stringResource(R.string.settings_server_checking) to MaterialTheme.colorScheme.onSurfaceVariant
        ServerStatus.Connected -> stringResource(R.string.settings_server_connected) to Color(0xFF16A34A)
        ServerStatus.NotSetUp -> stringResource(R.string.settings_server_not_set_up) to MaterialTheme.colorScheme.onSurfaceVariant
        ServerStatus.Unreachable -> stringResource(R.string.settings_server_unreachable) to MaterialTheme.colorScheme.error
    }
    SettingRow(
        icon = Icons.Filled.Dns,
        title = stringResource(R.string.settings_server),
        value = text,
        valueColor = color,
        trailing = {
            when (status) {
                ServerStatus.Checking -> CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
                ServerStatus.Connected -> Icon(Icons.Filled.CheckCircle, contentDescription = null, tint = color)
                ServerStatus.Unreachable -> Icon(Icons.Filled.CloudOff, contentDescription = null, tint = color)
                ServerStatus.NotSetUp -> Unit
            }
        },
        onClick = if (status == ServerStatus.Unreachable) onRetry else null,
    )
}

@Composable
private fun SectionHeader(@StringRes title: Int) {
    Column {
        HorizontalDivider(Modifier.padding(top = 8.dp), color = MaterialTheme.colorScheme.outlineVariant)
        Text(
            stringResource(title),
            style = MaterialTheme.typography.labelLarge,
            color = MaterialTheme.colorScheme.primary,
            modifier = Modifier
                .padding(start = 16.dp, end = 16.dp, top = 16.dp, bottom = 4.dp)
                .semantics { heading() },
        )
    }
}

@Composable
private fun Footer(text: String) {
    Text(
        text,
        style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.padding(start = 56.dp, end = 16.dp, bottom = 8.dp),
    )
}

@Composable
private fun SettingRow(
    icon: ImageVector,
    title: String,
    value: String,
    valueColor: Color = MaterialTheme.colorScheme.onSurfaceVariant,
    trailing: (@Composable () -> Unit)? = null,
    onClick: (() -> Unit)? = null,
) {
    ListItem(
        headlineContent = { Text(title) },
        supportingContent = { Text(value, color = valueColor) },
        leadingContent = { Icon(icon, contentDescription = null, tint = MaterialTheme.colorScheme.primary) },
        trailingContent = trailing,
        modifier = if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier,
    )
}

/** Material single-choice dialog: tapping an option saves it and closes. */
@Composable
private fun <T> ChoiceDialog(
    title: String,
    options: List<T>,
    selected: T,
    label: @Composable (T) -> String,
    detail: (@Composable (T) -> String)? = null,
    onSelect: (T) -> Unit,
    onDismiss: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = {
            Column(Modifier.selectableGroup(), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                for (option in options) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier
                            .fillMaxWidth()
                            .heightIn(min = 52.dp)
                            .selectable(
                                selected = option == selected,
                                role = Role.RadioButton,
                                onClick = {
                                    onSelect(option)
                                    onDismiss()
                                },
                            ),
                    ) {
                        RadioButton(selected = option == selected, onClick = null)
                        Spacer(Modifier.width(12.dp))
                        Column {
                            Text(label(option), style = MaterialTheme.typography.bodyLarge)
                            if (detail != null) {
                                Text(
                                    detail(option),
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                            }
                        }
                    }
                }
            }
        },
        confirmButton = {},
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.action_cancel)) } },
    )
}

// MARK: - Labels

private val Appearance.label: Int
    @StringRes get() = when (this) {
        Appearance.System -> R.string.settings_appearance_system
        Appearance.Light -> R.string.settings_appearance_light
        Appearance.Dark -> R.string.settings_appearance_dark
    }

private val ScanFilter.label: Int
    @StringRes get() = when (this) {
        ScanFilter.Original -> R.string.settings_filter_original
        ScanFilter.MagicColor -> R.string.settings_filter_magic_color
        ScanFilter.Grayscale -> R.string.settings_filter_grayscale
        ScanFilter.BlackWhite -> R.string.settings_filter_black_white
        ScanFilter.Lighten -> R.string.settings_filter_lighten
    }

/** Short speed/quality note shown under each model. */
val AnswerModel.detail: Int
    @StringRes get() = when (this) {
        AnswerModel.Opus -> R.string.settings_model_opus_detail
        AnswerModel.Sonnet -> R.string.settings_model_sonnet_detail
        AnswerModel.Haiku -> R.string.settings_model_haiku_detail
    }

private val PdfPageSize.label: Int
    @StringRes get() = when (this) {
        PdfPageSize.Auto -> R.string.settings_page_size_auto
        PdfPageSize.A4 -> R.string.settings_page_size_a4
        PdfPageSize.Letter -> R.string.settings_page_size_letter
    }
