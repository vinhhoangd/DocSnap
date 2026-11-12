package com.vinhhoang.docsnap

import android.app.Application
import com.vinhhoang.docsnap.answer.AnswerClient
import com.vinhhoang.docsnap.data.CacheCleanup
import com.vinhhoang.docsnap.data.DocumentStore
import com.vinhhoang.docsnap.data.Settings
import com.vinhhoang.docsnap.processing.PageRenderer
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import java.io.File

/** App-wide singletons (no DI framework needed at this size). */
class DocSnapApp : Application() {
    lateinit var store: DocumentStore
        private set
    lateinit var settings: Settings
        private set
    lateinit var answers: AnswerClient
        private set
    val appScope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    override fun onCreate() {
        super.onCreate()
        settings = Settings(this)
        store = DocumentStore(File(filesDir, "documents"), PageRenderer::render)
        answers = AnswerClient(BuildConfig.API_URL, BuildConfig.APP_TOKEN)
        appScope.launch { store.load() }
        // Only old temporary files go: an app that was shared a PDF may be what started us, and it
        // still needs that file. Off the main thread, so a full cache never delays launch.
        appScope.launch(Dispatchers.IO) {
            runCatching { CacheCleanup.deleteOlderThan(File(cacheDir, "exports"), CacheCleanup.EXPORT_MAX_AGE_MS) }
            runCatching { CacheCleanup.deleteOlderThan(File(cacheDir, "scans"), CacheCleanup.SCAN_MAX_AGE_MS) }
        }
    }
}
