package com.vinhhoang.docsnap

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.getValue
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import com.vinhhoang.docsnap.ui.document.DocumentScreen
import com.vinhhoang.docsnap.ui.library.LibraryScreen
import com.vinhhoang.docsnap.ui.page.PageViewerScreen
import com.vinhhoang.docsnap.ui.settings.SettingsScreen
import com.vinhhoang.docsnap.ui.theme.DocSnapTheme

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val app = application as DocSnapApp
        setContent {
            val appearance by app.settings.appearance.collectAsStateWithLifecycle()
            DocSnapTheme(appearance) {
                val nav = rememberNavController()
                NavHost(navController = nav, startDestination = Routes.LIBRARY) {
                    composable(Routes.LIBRARY) {
                        LibraryScreen(
                            onOpenDocument = { nav.navigate(Routes.document(it)) },
                            onOpenSettings = { nav.navigate(Routes.SETTINGS) },
                        )
                    }
                    composable(Routes.DOCUMENT, arguments = listOf(navArgument("id") { type = NavType.StringType })) { entry ->
                        DocumentScreen(
                            documentId = entry.arguments?.getString("id").orEmpty(),
                            onBack = { nav.popBackStack() },
                            onOpenPage = { id, index -> nav.navigate(Routes.page(id, index)) },
                        )
                    }
                    composable(
                        Routes.PAGE,
                        arguments = listOf(
                            navArgument("id") { type = NavType.StringType },
                            navArgument("index") { type = NavType.IntType },
                        ),
                    ) { entry ->
                        PageViewerScreen(
                            documentId = entry.arguments?.getString("id").orEmpty(),
                            startIndex = entry.arguments?.getInt("index") ?: 0,
                            onBack = { nav.popBackStack() },
                        )
                    }
                    composable(Routes.SETTINGS) { SettingsScreen(onBack = { nav.popBackStack() }) }
                }
            }
        }
    }
}

object Routes {
    const val LIBRARY = "library"
    const val DOCUMENT = "document/{id}"
    const val PAGE = "page/{id}/{index}"
    const val SETTINGS = "settings"
    fun document(id: String) = "document/$id"
    fun page(id: String, index: Int) = "page/$id/$index"
}
