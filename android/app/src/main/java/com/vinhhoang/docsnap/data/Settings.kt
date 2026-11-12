package com.vinhhoang.docsnap.data

import android.content.Context
import com.vinhhoang.docsnap.export.PdfPageSize
import com.vinhhoang.docsnap.model.ScanFilter
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

enum class Appearance(val raw: String) { System("system"), Light("light"), Dark("dark") }

/** Claude models the Answer server accepts (same list as the iPhone app). */
enum class AnswerModel(val id: String) {
    Opus("claude-opus-5-5"), Sonnet("claude-sonnet-5-5"), Haiku("claude-haiku-5-5")
}

enum class LibraryLayout { Grid, List }

/** User preferences (SharedPreferences), exposed as StateFlows for Compose. */
class Settings(context: Context) {
    private val prefs = context.getSharedPreferences("settings", Context.MODE_PRIVATE)

    private val _appearance = MutableStateFlow(enumOr(prefs.getString(KEY_APPEARANCE, null), Appearance.System) { it.raw })
    val appearance: StateFlow<Appearance> = _appearance.asStateFlow()

    private val _defaultFilter = MutableStateFlow(ScanFilter.fromRaw(prefs.getString(KEY_FILTER, null)))
    val defaultFilter: StateFlow<ScanFilter> = _defaultFilter.asStateFlow()

    private val _answerModel = MutableStateFlow(enumOr(prefs.getString(KEY_MODEL, null), AnswerModel.Opus) { it.id })
    val answerModel: StateFlow<AnswerModel> = _answerModel.asStateFlow()

    private val _libraryLayout = MutableStateFlow(enumOr(prefs.getString(KEY_LAYOUT, null), LibraryLayout.Grid) { it.name })
    val libraryLayout: StateFlow<LibraryLayout> = _libraryLayout.asStateFlow()

    private val _pdfPageSize = MutableStateFlow(enumOr(prefs.getString(KEY_PDF_SIZE, null), PdfPageSize.Auto) { it.name })
    val pdfPageSize: StateFlow<PdfPageSize> = _pdfPageSize.asStateFlow()

    fun setAppearance(value: Appearance) { _appearance.value = value; prefs.edit().putString(KEY_APPEARANCE, value.raw).apply() }
    fun setDefaultFilter(value: ScanFilter) { _defaultFilter.value = value; prefs.edit().putString(KEY_FILTER, value.raw).apply() }
    fun setAnswerModel(value: AnswerModel) { _answerModel.value = value; prefs.edit().putString(KEY_MODEL, value.id).apply() }
    fun setLibraryLayout(value: LibraryLayout) { _libraryLayout.value = value; prefs.edit().putString(KEY_LAYOUT, value.name).apply() }
    fun setPdfPageSize(value: PdfPageSize) { _pdfPageSize.value = value; prefs.edit().putString(KEY_PDF_SIZE, value.name).apply() }

    private companion object {
        const val KEY_APPEARANCE = "appearance"
        const val KEY_FILTER = "defaultFilter"
        const val KEY_MODEL = "answerModel"
        const val KEY_LAYOUT = "libraryLayout"
        const val KEY_PDF_SIZE = "pdfPageSize"

        inline fun <reified E : Enum<E>> enumOr(raw: String?, default: E, key: (E) -> String): E =
            enumValues<E>().firstOrNull { key(it) == raw } ?: default
    }
}
