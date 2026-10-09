package today.cypherpunk.emanator.util

import java.time.Duration
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.Locale

/** API times are ISO8601 UTC; everything is shown in the phone's zone. */
object Times {
    fun parse(iso: String?): ZonedDateTime? = iso?.let {
        runCatching { Instant.parse(it).atZone(ZoneId.systemDefault()) }.getOrNull()
    }

    fun iso(time: ZonedDateTime): String = time.toInstant().toString()

    fun hour(time: ZonedDateTime?): String =
        time?.format(DateTimeFormatter.ofPattern("HH:mm")) ?: "--:--"

    fun dayMonth(time: ZonedDateTime): String =
        time.format(DateTimeFormatter.ofPattern("d MMM", Locale.getDefault()))

    fun dateTime(time: ZonedDateTime?): String =
        time?.format(DateTimeFormatter.ofLocalizedDateTime(FormatStyle.MEDIUM, FormatStyle.SHORT).withLocale(Locale.getDefault())) ?: ""

    fun date(time: ZonedDateTime?): String =
        time?.format(DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM).withLocale(Locale.getDefault())) ?: ""

    fun isToday(time: ZonedDateTime) = time.toLocalDate() == LocalDate.now()
    fun isTomorrow(time: ZonedDateTime) = time.toLocalDate() == LocalDate.now().plusDays(1)

    /** "03:12" since a moment, for the waiting-for-approval counter. */
    fun elapsed(since: ZonedDateTime?, now: Instant = Instant.now()): String {
        if (since == null) return "00:00"
        val seconds = Duration.between(since.toInstant(), now).seconds.coerceAtLeast(0)
        val h = seconds / 3600
        val m = (seconds % 3600) / 60
        val s = seconds % 60
        return if (h > 0) "%d:%02d:%02d".format(h, m, s) else "%02d:%02d".format(m, s)
    }

    /** Compact "5m", "3h", "2d" age. */
    fun age(time: ZonedDateTime?, now: Instant = Instant.now()): String {
        if (time == null) return ""
        val minutes = Duration.between(time.toInstant(), now).toMinutes().coerceAtLeast(0)
        return when {
            minutes < 1 -> "<1m"
            minutes < 60 -> "${minutes}m"
            minutes < 60 * 24 -> "${minutes / 60}h"
            minutes < 60 * 24 * 30 -> "${minutes / (60 * 24)}d"
            else -> date(time)
        }
    }
}
