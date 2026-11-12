package com.vinhhoang.docsnap.ui

import androidx.compose.material3.Text
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.navigation.NavHostController
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.vinhhoang.docsnap.ui.common.ifResumed
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** The navigation guard MainActivity uses on every Back and link (ifResumed). */
@RunWith(AndroidJUnit4::class)
class NavGuardTest {
    @get:Rule val compose = createComposeRule()

    private lateinit var nav: NavHostController
    private lateinit var open: () -> Unit
    private lateinit var back: () -> Unit

    private fun show() {
        compose.setContent {
            nav = rememberNavController()
            NavHost(navController = nav, startDestination = "library") {
                composable("library") { entry ->
                    open = { entry.ifResumed { nav.navigate("document") } }
                    Text("library")
                }
                composable("document") { entry ->
                    back = { entry.ifResumed { nav.popBackStack() } }
                    Text("document")
                }
            }
        }
        compose.waitForIdle()
    }

    /** The bug: two quick Back taps popped the library too and left a blank screen. */
    @Test fun doubleBackPopsOnlyOnce() {
        show()
        compose.runOnUiThread { open() }
        compose.waitForIdle()
        compose.onNodeWithText("document").assertIsDisplayed()

        compose.runOnUiThread { back(); back() }
        compose.waitForIdle()

        assertEquals("library", nav.currentDestination?.route)
        compose.onNodeWithText("library").assertIsDisplayed()
    }

    @Test fun doubleTapOnALinkOpensOneScreen() {
        show()
        compose.runOnUiThread { open(); open() }
        compose.waitForIdle()
        assertEquals("document", nav.currentDestination?.route)

        compose.runOnUiThread { back() }
        compose.waitForIdle()
        assertEquals("library", nav.currentDestination?.route)
    }
}
