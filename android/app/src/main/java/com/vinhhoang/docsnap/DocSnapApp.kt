package com.vinhhoang.docsnap

import android.app.Application
import com.vinhhoang.docsnap.answer.AnswerClient
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
        // Scanner hand-offs and shared exports are temporary.
        File(cacheDir, "exports").deleteRecursively()
    }
}
