package today.cypherpunk.emanator.ui.screens.posts

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowLeft
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.LifecycleEventEffect
import androidx.lifecycle.viewModelScope
import androidx.navigation.NavHostController
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import today.cypherpunk.emanator.AppContainer
import today.cypherpunk.emanator.R
import today.cypherpunk.emanator.data.AccountMini
import today.cypherpunk.emanator.data.CalendarResponse
import today.cypherpunk.emanator.data.Loadable
import today.cypherpunk.emanator.data.PostItem
import today.cypherpunk.emanator.data.cachedFlow
import today.cypherpunk.emanator.ui.Routes
import today.cypherpunk.emanator.ui.appViewModel
import today.cypherpunk.emanator.ui.components.ConsoleScaffold
import today.cypherpunk.emanator.ui.components.EmptyState
import today.cypherpunk.emanator.ui.components.Gutter
import today.cypherpunk.emanator.ui.components.Legend
import today.cypherpunk.emanator.ui.components.LoadableContent
import today.cypherpunk.emanator.ui.components.PostRow
import today.cypherpunk.emanator.ui.components.Rule
import today.cypherpunk.emanator.ui.components.SlugButton
import today.cypherpunk.emanator.ui.theme.LocalConsole
import today.cypherpunk.emanator.ui.theme.Palette
import today.cypherpunk.emanator.ui.theme.Type
import today.cypherpunk.emanator.util.Times
import java.time.DayOfWeek
import java.time.LocalDate
import java.time.YearMonth
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.TextStyle
import java.time.temporal.TemporalAdjusters
import java.util.Locale

/**
 * The month on the stone (web: calendar/index). Weeks start on Monday; each
 * day carries a dot per post in its identity's ink, and tapping a day lists
 * what goes out then. Times are bucketed in the phone's zone, which the app
 * keeps in step with the user's server-side zone.
 */
class CalendarViewModel(private val container: AppContainer) : ViewModel() {
    val month = MutableStateFlow(YearMonth.now())
    val selected = MutableStateFlow<LocalDate?>(LocalDate.now())
    val state = MutableStateFlow(Loadable<CalendarResponse>())
    private var job: Job? = null

    init { refresh() }

    fun gridStart(m: YearMonth): LocalDate = m.atDay(1).with(TemporalAdjusters.previousOrSame(DayOfWeek.MONDAY))
    fun gridEnd(m: YearMonth): LocalDate = m.atEndOfMonth().with(TemporalAdjusters.nextOrSame(DayOfWeek.SUNDAY))

    fun refresh() {
        val m = month.value
        val zone = ZoneId.systemDefault()
        val from = gridStart(m).atStartOfDay(zone)
        val to = gridEnd(m).plusDays(1).atStartOfDay(zone)
        job?.cancel()
        job = viewModelScope.launch {
            cachedFlow(container.cache, "calendar:$m", CalendarResponse.serializer()) {
                container.api.calendar(Times.iso(from), Times.iso(to))
            }.collect { state.value = it }
        }
    }

    fun shift(months: Long) {
        month.value = month.value.plusMonths(months)
        val today = LocalDate.now()
        selected.value = if (YearMonth.from(today) == month.value) today else null
        state.value = Loadable()
        refresh()
    }

    fun goToday() {
        month.value = YearMonth.now()
        selected.value = LocalDate.now()
        refresh()
    }

    fun select(day: LocalDate) { selected.value = day }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
fun CalendarScreen(nav: NavHostController) {
    val vm = appViewModel { CalendarViewModel(it) }
    val month by vm.month.collectAsState()
    val selected by vm.selected.collectAsState()
    val state by vm.state.collectAsState()
    val c = LocalConsole.current

    LifecycleEventEffect(Lifecycle.Event.ON_RESUME) { vm.refresh() }

    ConsoleScaffold(title = stringResource(R.string.calendar_title)) { padding ->
        Column(Modifier.padding(padding)) {
            Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = { vm.shift(-1) }) {
                    Icon(Icons.AutoMirrored.Filled.KeyboardArrowLeft, contentDescription = stringResource(R.string.calendar_previous_month), tint = c.text)
                }
                Text(
                    month.atDay(1).format(DateTimeFormatter.ofPattern("LLLL yyyy", androidx.compose.ui.platform.LocalConfiguration.current.locales[0])).uppercase(),
                    style = Type.title, color = c.text, modifier = Modifier.weight(1f),
                )
                SlugButton(stringResource(R.string.calendar_today), vm::goToday)
                IconButton(onClick = { vm.shift(1) }) {
                    Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = stringResource(R.string.calendar_next_month), tint = c.text)
                }
            }
            Rule()
            LoadableContent(state, onRefresh = vm::refresh) { data ->
                val byDay = remember(data) {
                    data.items.groupBy { Times.parse(it.scheduledAt)?.toLocalDate() }.filterKeys { it != null }
                        .mapKeys { it.key!! }
                }
                Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState())) {
                    MonthGrid(month, vm.gridStart(month), vm.gridEnd(month), byDay, selected, vm::select)

                    val legend = remember(data) {
                        data.items.filter { YearMonth.from(Times.parse(it.scheduledAt) ?: return@filter false) == month }
                            .mapNotNull { it.account }.distinctBy { it.id }.sortedBy { it.name.lowercase() }
                    }
                    if (legend.isNotEmpty()) {
                        Legend(stringResource(R.string.calendar_who), Modifier.padding(start = Gutter, end = Gutter, top = 16.dp, bottom = 8.dp))
                        FlowRow(Modifier.padding(horizontal = Gutter), horizontalArrangement = Arrangement.spacedBy(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                            legend.forEach { account ->
                                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                                    Box(Modifier.size(9.dp).background(inkOf(account)))
                                    Text(account.name, style = Type.small, color = c.legend)
                                }
                            }
                        }
                    }

                    selected?.let { day ->
                        val items = byDay[day].orEmpty().sortedBy { it.scheduledAt }
                        val posts = items.count { !it.isRepost }
                        val reposts = items.size - posts
                        val counts = buildList {
                            if (posts > 0) add(pluralStringResource(R.plurals.calendar_post_count, posts, posts))
                            if (reposts > 0) add(pluralStringResource(R.plurals.calendar_repost_count, reposts, reposts))
                        }.joinToString(" · ")
                        Legend(
                            listOf(Times.date(day.atStartOfDay(ZoneId.systemDefault())), counts).filter { it.isNotBlank() }.joinToString(" · "),
                            Modifier.padding(start = Gutter, end = Gutter, top = 24.dp, bottom = 6.dp),
                        )
                        Rule()
                        if (items.isEmpty()) {
                            EmptyState(stringResource(R.string.calendar_nothing_on_day))
                        } else {
                            items.forEach { PostRow(it, onOpen = { item -> nav.navigate(Routes.post(item.targetPostId)) }) }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun MonthGrid(
    month: YearMonth,
    start: LocalDate,
    end: LocalDate,
    byDay: Map<LocalDate, List<PostItem>>,
    selected: LocalDate?,
    onSelect: (LocalDate) -> Unit,
) {
    val c = LocalConsole.current
    val today = LocalDate.now()
    Column(Modifier.padding(horizontal = 8.dp, vertical = 8.dp)) {
        Row(Modifier.fillMaxWidth()) {
            DayOfWeek.entries.forEach { dow ->
                Text(
                    dow.getDisplayName(TextStyle.SHORT, androidx.compose.ui.platform.LocalConfiguration.current.locales[0]).uppercase(),
                    style = Type.slug, color = c.muted,
                    modifier = Modifier.weight(1f).padding(vertical = 6.dp),
                    textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                )
            }
        }
        var day = start
        while (!day.isAfter(end)) {
            Row(Modifier.fillMaxWidth()) {
                repeat(7) {
                    val d = day
                    val items = byDay[d].orEmpty()
                    val inMonth = YearMonth.from(d) == month
                    Column(
                        Modifier
                            .weight(1f)
                            .aspectRatio(0.9f)
                            .border(0.5.dp, c.rule)
                            .then(if (d == today) Modifier.background(c.activeFill) else Modifier)
                            .then(if (d == selected) Modifier.border(1.5.dp, Palette.amber) else Modifier)
                            .clickable { onSelect(d) }
                            .padding(4.dp),
                        verticalArrangement = Arrangement.SpaceBetween,
                    ) {
                        Text(
                            d.dayOfMonth.toString(),
                            style = Type.readout,
                            color = when {
                                !inMonth -> c.muted.copy(alpha = 0.5f)
                                d == today -> c.amberText
                                else -> c.text
                            },
                        )
                        if (items.isNotEmpty()) {
                            Row(horizontalArrangement = Arrangement.spacedBy(2.dp), verticalAlignment = Alignment.CenterVertically) {
                                items.take(4).forEach { item ->
                                    val waiting = item.status == "awaiting_signature" || item.status == "pending_signature"
                                    val failed = item.status == "failed"
                                    Box(
                                        Modifier.size(7.dp).clip(if (item.isRepost) CircleShape else androidx.compose.ui.graphics.RectangleShape)
                                            .background(
                                                when {
                                                    failed -> c.red
                                                    waiting -> c.amber
                                                    else -> item.account?.let { inkOf(it) } ?: c.lampLit
                                                },
                                            ),
                                    )
                                }
                                if (items.size > 4) Text("+${items.size - 4}", style = Type.slug, color = c.muted)
                            }
                        } else {
                            Box(Modifier.height(7.dp))
                        }
                    }
                    day = day.plusDays(1)
                }
            }
        }
    }
}

private fun inkOf(account: AccountMini): Color =
    runCatching { Color(android.graphics.Color.parseColor(account.ink)) }.getOrDefault(Palette.neutral500)
