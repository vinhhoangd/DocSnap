package com.vinhhoang.docsnap.ui

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.assertIsNotSelected
import androidx.compose.ui.test.assertIsSelected
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.vinhhoang.docsnap.model.ScanFilter
import com.vinhhoang.docsnap.ui.page.FilterStrip
import com.vinhhoang.docsnap.ui.page.filterLabel
import com.vinhhoang.docsnap.ui.theme.DocSnapTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class FilterStripTest {
    @get:Rule val compose = createComposeRule()

    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private val picked = mutableListOf<ScanFilter>()

    private fun show(initial: ScanFilter) {
        compose.setContent {
            DocSnapTheme {
                var selected by remember { mutableStateOf(initial) }
                FilterStrip(selected = selected, onSelect = { picked += it; selected = it })
            }
        }
    }

    @Test fun showsAllFiveFiltersWithNames() {
        show(ScanFilter.MagicColor)
        ScanFilter.entries.forEach { filter ->
            compose.onNodeWithTag("filter-${filter.raw}").performScrollTo()
            compose.onNodeWithText(context.getString(filterLabel(filter))).assertExists()
        }
    }

    @Test fun currentFilterIsSelected() {
        show(ScanFilter.Grayscale)
        compose.onNodeWithTag("filter-grayscale").assertIsSelected()
        compose.onNodeWithTag("filter-magicColor").assertIsNotSelected()
    }

    @Test fun tappingAnotherFilterSelectsIt() {
        show(ScanFilter.MagicColor)
        compose.onNodeWithTag("filter-blackWhite").performScrollTo().performClick()
        assertEquals(listOf(ScanFilter.BlackWhite), picked)
        compose.onNodeWithTag("filter-blackWhite").assertIsSelected()
        compose.onNodeWithTag("filter-magicColor").assertIsNotSelected()
    }

    @Test fun tappingTheSelectedFilterDoesNothing() {
        show(ScanFilter.Original)
        compose.onNodeWithTag("filter-original").performClick()
        assertTrue(picked.isEmpty())
    }

    @Test fun everyFilterCanBePicked() {
        show(ScanFilter.Original)
        val order = listOf(ScanFilter.MagicColor, ScanFilter.Grayscale, ScanFilter.BlackWhite, ScanFilter.Lighten, ScanFilter.Original)
        order.forEach { compose.onNodeWithTag("filter-${it.raw}").performScrollTo().performClick() }
        assertEquals(order, picked)
    }
}
