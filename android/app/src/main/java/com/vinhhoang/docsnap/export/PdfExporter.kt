package com.vinhhoang.docsnap.export

import com.vinhhoang.docsnap.data.DocumentStore
import com.vinhhoang.docsnap.model.ScanDocument
import java.io.File

/** Page size for exported PDFs. Auto = each page sized to its image's aspect ratio. */
enum class PdfPageSize { Auto, A4, Letter }

object PdfExporter {
    /** Writes `doc`'s processed pages to a PDF in `outputDir`, named after the title; returns the file. */
    fun export(doc: ScanDocument, store: DocumentStore, outputDir: File, pageSize: PdfPageSize = PdfPageSize.Auto): File {
        TODO("processing agent")
    }
}
