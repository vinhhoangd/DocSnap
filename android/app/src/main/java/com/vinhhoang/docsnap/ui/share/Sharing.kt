package com.vinhhoang.docsnap.ui.share

import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.widget.Toast
import androidx.core.content.FileProvider
import com.vinhhoang.docsnap.R
import com.vinhhoang.docsnap.data.DocumentStore
import com.vinhhoang.docsnap.model.ScanDocument
import com.vinhhoang.docsnap.ui.theme.showsOwnCopyToast
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.util.UUID

/**
 * Hands files to other apps (Zalo, Gmail, Quick Share, Drive, …) through the system share sheet.
 * Files must live under cache/exports (the only folder res/xml/file_paths.xml exposes).
 */
object Sharing {
    const val MIME_PDF = "application/pdf"
    const val MIME_JPEG = "image/jpeg"

    fun exportsDir(context: Context) = File(context.cacheDir, "exports")

    /** A fresh folder per share, so two shares never overwrite each other's files. */
    fun newExportFolder(context: Context): File =
        File(exportsDir(context), UUID.randomUUID().toString()).apply { mkdirs() }

    /** Copies the document's processed pages into a new export folder as "Title - 01.jpg", … */
    suspend fun prepareImages(context: Context, doc: ScanDocument, store: DocumentStore): List<File> =
        withContext(Dispatchers.IO) {
            val folder = newExportFolder(context)
            val base = ExportNames.safeBaseName(doc.title)
            doc.pages.mapIndexed { index, page ->
                val target = File(folder, ExportNames.imageName(base, index, doc.pages.size))
                store.processedFile(doc.id, page.id).copyTo(target, overwrite = true)
            }
        }

    /** Opens the share sheet for one or more files of one type. Returns false if no app can take them. */
    fun shareFiles(context: Context, files: List<File>, mime: String, subject: String): Boolean {
        if (files.isEmpty()) return false
        val uris = files.map { uriFor(context, it) }
        val intent = if (uris.size == 1) {
            Intent(Intent.ACTION_SEND).putExtra(Intent.EXTRA_STREAM, uris.first())
        } else {
            Intent(Intent.ACTION_SEND_MULTIPLE).putParcelableArrayListExtra(Intent.EXTRA_STREAM, ArrayList(uris))
        }
        intent.type = mime
        intent.putExtra(Intent.EXTRA_SUBJECT, subject)
        // ClipData carries the read grant through the chooser to the app that's picked (and gives a preview).
        intent.clipData = ClipData(subject, arrayOf(mime), ClipData.Item(uris.first())).apply {
            uris.drop(1).forEach { addItem(ClipData.Item(it)) }
        }
        intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        return startChooser(context, intent)
    }

    fun shareText(context: Context, text: String, subject: String): Boolean {
        val intent = Intent(Intent.ACTION_SEND)
            .setType("text/plain")
            .putExtra(Intent.EXTRA_TEXT, text)
            .putExtra(Intent.EXTRA_SUBJECT, subject)
        return startChooser(context, intent)
    }

    /** Puts text on the clipboard; shows our own "Copied" toast where Android doesn't show one. */
    fun copyText(context: Context, label: String, text: String) {
        val clipboard = context.getSystemService(ClipboardManager::class.java) ?: return
        clipboard.setPrimaryClip(ClipData.newPlainText(label, text))
        if (!showsOwnCopyToast) Toast.makeText(context, R.string.lib_copied, Toast.LENGTH_SHORT).show()
    }

    private fun uriFor(context: Context, file: File): Uri =
        FileProvider.getUriForFile(context, "${context.packageName}.files", file)

    private fun startChooser(context: Context, intent: Intent): Boolean {
        val chooser = Intent.createChooser(intent, context.getString(R.string.lib_share_chooser_title))
        if (context !is android.app.Activity) chooser.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        return try {
            context.startActivity(chooser)
            true
        } catch (_: ActivityNotFoundException) {
            false
        }
    }
}
