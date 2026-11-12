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
import com.vinhhoang.docsnap.ui.common.ifResumed
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
                // Every navigation runs only from the resumed screen (ifResumed), so a double tap on
                // Back can't pop past the library and a double tap on a link opens one screen.
                NavHost(navController = nav, startDestination = Routes.LIBRARY) {
                    composable(Routes.LIBRARY) { entry ->
                        LibraryScreen(
                            onOpenDocument = { id -> entry.ifResumed { nav.navigate(Routes.document(id)) } },
                            onOpenSettings = { entry.ifResumed { nav.navigate(Routes.SETTINGS) } },
                        )
                    }
                    composable(Routes.DOCUMENT, arguments = listOf(navArgument("id") { type = NavType.StringType })) { entry ->
                        DocumentScreen(
                            documentId = entry.arguments?.getString("id").orEmpty(),
                            onBack = { entry.ifResumed { nav.popBackStack() } },
                            onOpenPage = { id, index -> entry.ifResumed { nav.navigate(Routes.page(id, index)) } },
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
                            onBack = { entry.ifResumed { nav.popBackStack() } },
                        )
                    }
                    composable(Routes.SETTINGS) { entry ->
                        SettingsScreen(onBack = { entry.ifResumed { nav.popBackStack() } })
                    }
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
