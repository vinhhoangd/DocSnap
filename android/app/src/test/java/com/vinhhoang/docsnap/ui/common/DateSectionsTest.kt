package com.vinhhoang.docsnap.ui.common

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDateTime
import java.time.ZoneId
import java.util.Locale

class DateSectionsTest {
    private val hcm = ZoneId.of("Asia/Ho_Chi_Minh")
    private val newYork = ZoneId.of("America/New_York")

    private fun at(y: Int, m: Int, d: Int, h: Int = 12, min: Int = 0, s: Int = 0, nanos: Int = 0, zone: ZoneId = hcm): Long =
        LocalDateTime.of(y, m, d, h, min, s, nanos).atZone(zone).toInstant().toEpochMilli()

    private fun section(time: Long, now: Long, zone: ZoneId = hcm) = DateSections.sectionOf(time, now, zone)

    @Test fun sameMomentIsToday() {
        val now = at(2026, 11, 12, 14, 30)
        assertEquals(DateSection.Today, section(now, now))
    }

    @Test fun midnightStartOfTodayIsToday() {
        assertEquals(DateSection.Today, section(at(2026, 11, 12, 0, 0), at(2026, 11, 12, 23, 59)))
    }

    @Test fun oneMillisecondBeforeMidnightIsYesterday() {
        val justBefore = at(2026, 11, 12, 0, 0) - 1
        assertEquals(DateSection.Yesterday, section(justBefore, at(2026, 11, 12, 0, 0, 1)))
    }

    @Test fun justAfterMidnightTheEveningBeforeIsYesterdayEvenIfMinutesApart() {
        // 23:59 yesterday vs 00:01 today: two minutes apart but a different calendar day.
        assertEquals(DateSection.Yesterday, section(at(2026, 11, 11, 23, 59), at(2026, 11, 12, 0, 1)))
    }

    @Test fun twentyThreeHoursAgoOnTheSameDayIsToday() {
        assertEquals(DateSection.Today, section(at(2026, 11, 12, 0, 30), at(2026, 11, 12, 23, 30)))
    }

    @Test fun twoToSixDaysAgoArePrevious7Days() {
        val now = at(2026, 11, 12)
        for (days in 2..6) {
            assertEquals("days=$days", DateSection.Previous7Days, section(at(2026, 11, 12 - days), now))
        }
    }

    @Test fun sevenDaysAgoFallsIntoItsMonth() {
        assertEquals(DateSection.Month(2026, 11), section(at(2026, 11, 5, 23, 59), at(2026, 11, 12, 0, 1)))
    }

    @Test fun previous7DaysCrossesMonthBoundary() {
        // 3 days before Dec 2 is Nov 29: still "Previous 7 Days", not "November".
        assertEquals(DateSection.Previous7Days, section(at(2026, 11, 29), at(2026, 12, 2)))
    }

    @Test fun yesterdayCrossesMonthBoundary() {
        assertEquals(DateSection.Yesterday, section(at(2026, 10, 31, 23, 0), at(2026, 11, 1, 8, 0)))
    }

    @Test fun yesterdayCrossesYearBoundary() {
        assertEquals(DateSection.Yesterday, section(at(2025, 12, 31, 22, 0), at(2026, 1, 1, 1, 0)))
    }

    @Test fun olderDatesGroupByMonthAndYear() {
        val now = at(2026, 11, 12)
        assertEquals(DateSection.Month(2026, 10), section(at(2026, 10, 1, 0, 0), now))
        assertEquals(DateSection.Month(2026, 9), section(at(2026, 9, 30, 23, 59), now))
        assertEquals(DateSection.Month(2025, 11), section(at(2025, 11, 20), now))
    }

    @Test fun lastSecondOfAMonthStaysInThatMonth() {
        val now = at(2026, 11, 30)
        assertEquals(DateSection.Month(2026, 10), section(at(2026, 10, 31, 23, 59, 59, 999_000_000), now))
        assertEquals(DateSection.Month(2026, 11), section(at(2026, 11, 1, 0, 0), now))
    }

    @Test fun futureTimesCountAsToday() {
        assertEquals(DateSection.Today, section(at(2026, 11, 14), at(2026, 11, 12)))
    }

    @Test fun calendarDayDependsOnTimeZone() {
        // 01:00 on Nov 12 in Vietnam is still Nov 11 in New York.
        val time = at(2026, 11, 12, 1, 0, zone = hcm)
        val now = at(2026, 11, 12, 20, 0, zone = hcm)
        assertEquals(DateSection.Today, section(time, now, hcm))
        assertEquals(DateSection.Yesterday, section(time, at(2026, 11, 12, 12, 0, zone = newYork), newYork))
    }

    @Test fun daylightSavingDayIsStillOneDay() {
        // New York springs forward on 2026-03-08 (a 23-hour day).
        assertEquals(DateSection.Yesterday, section(at(2026, 3, 7, 23, 30, zone = newYork), at(2026, 3, 8, 23, 30, zone = newYork), newYork))
    }

    @Test fun groupKeepsOrderAndSplitsBySection() {
        val now = at(2026, 11, 12, 18)
        val items = listOf(
            "a" to at(2026, 11, 12, 17),
            "b" to at(2026, 11, 12, 9),
            "c" to at(2026, 11, 11, 20),
            "d" to at(2026, 11, 9),
            "e" to at(2026, 10, 3),
            "f" to at(2026, 10, 1),
            "g" to at(2025, 12, 25),
        )
        val groups = DateSections.group(items, now, hcm) { it.second }
        assertEquals(
            listOf(DateSection.Today, DateSection.Yesterday, DateSection.Previous7Days, DateSection.Month(2026, 10), DateSection.Month(2025, 12)),
            groups.map { it.first },
        )
        assertEquals(listOf("a", "b"), groups[0].second.map { it.first })
        assertEquals(listOf("e", "f"), groups[3].second.map { it.first })
    }

    @Test fun groupOfNothingIsEmpty() {
        assertTrue(DateSections.group(emptyList<Long>(), 0L, hcm) { it }.isEmpty())
    }

    @Test fun monthTitleOmitsCurrentYear() {
        assertEquals("November", DateSections.monthTitle(DateSection.Month(2026, 11), 2026, Locale.US))
        assertEquals("November 2025", DateSections.monthTitle(DateSection.Month(2025, 11), 2026, Locale.US))
    }

    @Test fun monthTitleInVietnameseIsCapitalized() {
        val title = DateSections.monthTitle(DateSection.Month(2026, 11), 2026, Locale.forLanguageTag("vi"))
        assertTrue(title, title.first().isUpperCase())
        assertTrue(title, title.contains("11"))
    }
}
