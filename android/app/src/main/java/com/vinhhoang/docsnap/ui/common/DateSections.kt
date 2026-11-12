package com.vinhhoang.docsnap.ui.common

import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.temporal.ChronoUnit
import java.util.Locale

/** Library sections by date, like the iPhone app: Today, Yesterday, Previous 7 Days, then one per month. */
sealed interface DateSection {
    data object Today : DateSection
    data object Yesterday : DateSection
    data object Previous7Days : DateSection
    data class Month(val year: Int, val month: Int) : DateSection
}

object DateSections {
    /** The section for a time, judged by calendar days in `zone` (not 24-hour spans). Future times count as Today. */
    fun sectionOf(epochMillis: Long, now: Long, zone: ZoneId): DateSection {
        val day = localDate(epochMillis, zone)
        val today = localDate(now, zone)
        val days = ChronoUnit.DAYS.between(day, today)
        return when {
            days <= 0 -> DateSection.Today
            days == 1L -> DateSection.Yesterday
            days < 7 -> DateSection.Previous7Days
            else -> DateSection.Month(day.year, day.monthValue)
        }
    }

    /**
     * Groups items (already sorted newest first) into sections, keeping their order inside each section.
     * Sections come out in the order their first item appears.
     */
    fun <T> group(items: List<T>, now: Long, zone: ZoneId, time: (T) -> Long): List<Pair<DateSection, List<T>>> {
        val map = LinkedHashMap<DateSection, MutableList<T>>()
        items.forEach { map.getOrPut(sectionOf(time(it), now, zone)) { mutableListOf() }.add(it) }
        return map.map { (section, list) -> section to list }
    }

    /** "November" in the current year, "November 2025" otherwise; first letter capitalized ("Tháng 11"). */
    fun monthTitle(section: DateSection.Month, currentYear: Int, locale: Locale): String {
        val pattern = if (section.year == currentYear) "LLLL" else "LLLL yyyy"
        val text = DateTimeFormatter.ofPattern(pattern, locale).format(LocalDate.of(section.year, section.month, 1))
        return text.replaceFirstChar { if (it.isLowerCase()) it.titlecase(locale) else it.toString() }
    }

    private fun localDate(epochMillis: Long, zone: ZoneId): LocalDate =
        Instant.ofEpochMilli(epochMillis).atZone(zone).toLocalDate()
}
