package today.cypherpunk.emanator.ui.screens.compose

import android.text.format.DateFormat
import android.widget.Toast
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CheckboxDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DatePicker
import androidx.compose.material3.DatePickerDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TimePicker
import androidx.compose.material3.rememberDatePickerState
import androidx.compose.material3.rememberTimePickerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import androidx.navigation.NavHostController
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import today.cypherpunk.emanator.AppContainer
import today.cypherpunk.emanator.R
import today.cypherpunk.emanator.data.ApiException
import today.cypherpunk.emanator.data.PostItem
import today.cypherpunk.emanator.data.ScheduleOptions
import today.cypherpunk.emanator.ui.Routes
import today.cypherpunk.emanator.ui.appViewModel
import today.cypherpunk.emanator.ui.components.AlarmBlock
import today.cypherpunk.emanator.ui.components.Chop
import today.cypherpunk.emanator.ui.components.ConsoleScaffold
import today.cypherpunk.emanator.ui.components.ErrorState
import today.cypherpunk.emanator.ui.components.Gutter
import today.cypherpunk.emanator.ui.components.Identity
import today.cypherpunk.emanator.ui.components.Legend
import today.cypherpunk.emanator.ui.components.PrimaryButton
import today.cypherpunk.emanator.ui.components.RichContent
import today.cypherpunk.emanator.ui.components.Rule
import today.cypherpunk.emanator.ui.components.SecondaryButton
import today.cypherpunk.emanator.ui.components.Slug
import today.cypherpunk.emanator.ui.components.SlugButton
import today.cypherpunk.emanator.ui.components.WaitBlock
import today.cypherpunk.emanator.ui.theme.LocalConsole
import today.cypherpunk.emanator.ui.theme.Palette
import today.cypherpunk.emanator.ui.theme.Type
import today.cypherpunk.emanator.util.Times
import java.time.Instant
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneId
import java.time.ZoneOffset
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.Locale

data class ScheduleUi(
    val loading: Boolean = true,
    val post: PostItem? = null,
    val options: ScheduleOptions? = null,
    val at: ZonedDateTime? = null,
    val reposts: Set<Long> = emptySet(),
    val maxDelay: String = "",
    val submitting: Boolean = false,
    val loadError: ApiException? = null,
    val error: String? = null,
    /** Set when a picked time is not in the future; the message is the app's own. */
    val pastTime: Boolean = false,
)

/**
 * Sign & schedule (web: posts/schedule + post_scheduler / repost_picker): a
 * time — defaulting to the server's suggested slot — the identities that should
 * also repost, and the window their reposts are spread across.
 */
class ScheduleViewModel(private val container: AppContainer, private val postId: Long, preselected: List<Long>) : ViewModel() {
    val ui = MutableStateFlow(ScheduleUi(reposts = preselected.toSet()))
    private val done = Channel<String?>(Channel.BUFFERED)
    val finished = done.receiveAsFlow()

    init { load() }

    fun load() {
        ui.update { it.copy(loading = true, loadError = null) }
        viewModelScope.launch {
            try {
                val post = container.api.post(postId).post
                val options = container.api.scheduleOptions(postId)
                val suggested = Times.parse(options.suggestedAt) ?: ZonedDateTime.now().plusHours(1)
                ui.update {
                    it.copy(
                        loading = false, post = post, options = options,
                        at = it.at ?: suggested.withSecond(0).withNano(0),
                        reposts = it.reposts + options.existingRepostAccountIds,
                        maxDelay = it.maxDelay.ifBlank { options.defaultMaxDelayHours.toString() },
                    )
                }
            } catch (e: ApiException) {
                ui.update { it.copy(loading = false, loadError = e) }
            }
        }
    }

    fun setDate(date: LocalDate) = ui.update { s ->
        val current = s.at ?: ZonedDateTime.now()
        s.copy(at = date.atTime(current.toLocalTime()).atZone(ZoneId.systemDefault()), pastTime = false)
    }

    fun setTime(hour: Int, minute: Int) = ui.update { s ->
        val current = s.at ?: ZonedDateTime.now()
        s.copy(at = current.with(LocalTime.of(hour, minute)), pastTime = false)
    }

    fun soon() = ui.update { s ->
        s.copy(at = ZonedDateTime.now().plusMinutes((s.options?.soonMinutes ?: 7).toLong()).withSecond(0).withNano(0), pastTime = false)
    }

    fun suggested() = ui.update { s -> Times.parse(s.options?.suggestedAt)?.let { s.copy(at = it, pastTime = false) } ?: s }

    fun toggleRepost(id: Long) = ui.update { s -> s.copy(reposts = if (id in s.reposts) s.reposts - id else s.reposts + id) }

    fun setReposts(ids: Set<Long>) = ui.update { it.copy(reposts = ids) }

    fun setMaxDelay(value: String) = ui.update { it.copy(maxDelay = value.filter(Char::isDigit).take(4)) }

    fun submit() {
        val state = ui.value
        val at = state.at ?: return
        if (state.submitting) return
        if (!at.isAfter(ZonedDateTime.now())) {
            ui.update { it.copy(pastTime = true) }
            return
        }
        val maxHours = state.options?.maxDelayHours ?: 8760
        val delayHours = (state.maxDelay.toIntOrNull() ?: state.options?.defaultMaxDelayHours ?: 1).coerceIn(1, maxHours)
        ui.update { it.copy(submitting = true, error = null) }
        viewModelScope.launch {
            try {
                val result = container.api.schedulePost(postId, Times.iso(at), state.reposts.toList(), delayHours)
                ui.update { it.copy(submitting = false) }
                done.send(result.message)
            } catch (e: ApiException) {
                ui.update { it.copy(submitting = false, error = e.message) }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ScheduleScreen(nav: NavHostController, id: Long, preselectedReposts: List<Long>) {
    val vm = appViewModel(key = "schedule-$id") { ScheduleViewModel(it, id, preselectedReposts) }
    val ui by vm.ui.collectAsState()
    val context = LocalContext.current
    val c = LocalConsole.current
    var pickDate by remember { mutableStateOf(false) }
    var pickTime by remember { mutableStateOf(false) }

    // Coming back from editing the text: show the new text, keep the picks.
    var resumedOnce by remember { mutableStateOf(false) }
    androidx.lifecycle.compose.LifecycleEventEffect(androidx.lifecycle.Lifecycle.Event.ON_RESUME) {
        if (resumedOnce) vm.load() else resumedOnce = true
    }

    LaunchedEffect(vm) {
        vm.finished.collect { message ->
            message?.let { Toast.makeText(context, it, Toast.LENGTH_LONG).show() }
            // Back to the post's page if it is underneath (it refreshes on
            // resume), otherwise open it in place of this screen.
            if (!nav.popBackStack(Routes.POST, inclusive = false)) {
                nav.navigate(Routes.post(id)) {
                    popUpTo(Routes.SCHEDULE) { inclusive = true }
                    launchSingleTop = true
                }
            }
        }
    }

    ConsoleScaffold(stringResource(R.string.schedule_title), onBack = { nav.popBackStack() }) { padding ->
        val options = ui.options
        val post = ui.post
        when {
            ui.loading && options == null -> Box(Modifier.padding(padding).fillMaxWidth().padding(40.dp), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(color = Palette.amber, strokeWidth = 2.dp)
            }
            options == null || post == null -> Box(Modifier.padding(padding)) {
                ui.loadError?.let { ErrorState(it, vm::load) }
            }
            else -> Column(
                Modifier.padding(padding).imePadding().verticalScroll(rememberScrollState()).padding(horizontal = Gutter, vertical = 16.dp),
                verticalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                Text(stringResource(R.string.schedule_subtitle), style = Type.small, color = c.muted)

                Legend(stringResource(R.string.schedule_preview)) {
                    SlugButton(stringResource(R.string.action_edit), { nav.navigate(Routes.compose(post = id)) })
                }
                Identity(post.account)
                RichContent(post.content, post.references, maxLines = 8)
                Rule()

                Legend(stringResource(R.string.schedule_time))
                val at = ui.at
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                    TimeField(at?.format(DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM).withLocale(Locale.getDefault())) ?: "",
                        stringResource(R.string.schedule_date), Modifier.weight(1.4f)) { pickDate = true }
                    TimeField(Times.hour(at), stringResource(R.string.schedule_clock), Modifier.weight(1f)) { pickTime = true }
                }
                Text(stringResource(R.string.schedule_zone, ZoneId.systemDefault().id), style = Type.small, color = c.muted)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                    SecondaryButton(stringResource(R.string.schedule_soon), vm::soon)
                    Times.parse(options.suggestedAt)?.let { suggested ->
                        SlugButton(stringResource(R.string.schedule_suggested, Times.dateTime(suggested)), vm::suggested)
                    }
                }
                Text(pluralStringResource(R.plurals.schedule_soon_hint, options.soonMinutes, options.soonMinutes), style = Type.small, color = c.muted)
                if (ui.pastTime) AlarmBlock(stringResource(R.string.schedule_in_past))

                if (options.repostAccounts.isNotEmpty()) {
                    Rule()
                    RepostPicker(ui, options, vm)
                }

                Rule()
                WaitBlock(stringResource(R.string.schedule_approve_note))
                ui.error?.let { AlarmBlock(it) }
                PrimaryButton(stringResource(R.string.schedule_sign), vm::submit, Modifier.fillMaxWidth(), busy = ui.submitting)
            }
        }
    }

    if (pickDate) {
        val initial = (ui.at ?: ZonedDateTime.now()).toLocalDate().atStartOfDay(ZoneOffset.UTC).toInstant().toEpochMilli()
        val state = rememberDatePickerState(initialSelectedDateMillis = initial)
        DatePickerDialog(
            onDismissRequest = { pickDate = false },
            confirmButton = {
                TextButton(onClick = {
                    state.selectedDateMillis?.let { vm.setDate(Instant.ofEpochMilli(it).atZone(ZoneOffset.UTC).toLocalDate()) }
                    pickDate = false
                }) { Text(stringResource(R.string.action_done)) }
            },
            dismissButton = { TextButton(onClick = { pickDate = false }) { Text(stringResource(R.string.action_cancel)) } },
        ) { DatePicker(state) }
    }
    if (pickTime) {
        val at = ui.at ?: ZonedDateTime.now()
        val state = rememberTimePickerState(at.hour, at.minute, DateFormat.is24HourFormat(context))
        AlertDialog(
            onDismissRequest = { pickTime = false },
            confirmButton = {
                TextButton(onClick = { vm.setTime(state.hour, state.minute); pickTime = false }) { Text(stringResource(R.string.action_done)) }
            },
            dismissButton = { TextButton(onClick = { pickTime = false }) { Text(stringResource(R.string.action_cancel)) } },
            text = { TimePicker(state) },
        )
    }
}

@Composable
private fun TimeField(value: String, label: String, modifier: Modifier, onClick: () -> Unit) {
    val c = LocalConsole.current
    Column(
        modifier.clickable(onClick = onClick).padding(vertical = 4.dp),
    ) {
        Text(label.uppercase(), style = Type.slug, color = c.muted)
        Text(value, style = Type.hour, color = c.text, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(top = 6.dp))
        Rule(Modifier.padding(top = 6.dp))
    }
}

/** "Also post as": other identities that repost at a random delay. */
@Composable
private fun RepostPicker(ui: ScheduleUi, options: ScheduleOptions, vm: ScheduleViewModel) {
    val c = LocalConsole.current
    var filter by remember { mutableStateOf("") }
    val shown = options.repostAccounts.filter { account ->
        filter.isBlank() || listOfNotNull(account.name, account.username, account.npub).any { it.contains(filter.trim(), ignoreCase = true) }
    }

    Legend(stringResource(R.string.schedule_also_post_as)) {
        if (shown.isNotEmpty()) SlugButton(stringResource(R.string.schedule_select_all), { vm.setReposts(ui.reposts + shown.map { it.id }) })
    }
    if (options.repostAccounts.size > 6) {
        OutlinedTextField(
            filter, { filter = it },
            placeholder = { Text(stringResource(R.string.schedule_filter), style = Type.small) },
            singleLine = true,
            textStyle = Type.bodyDense.copy(color = c.text),
            modifier = Modifier.fillMaxWidth(),
        )
    }
    if (shown.isEmpty()) Text(stringResource(R.string.schedule_no_match), style = Type.small, color = c.muted)
    shown.forEach { account ->
        Row(
            Modifier.fillMaxWidth().clickable { vm.toggleRepost(account.id) }.padding(vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Checkbox(
                checked = account.id in ui.reposts,
                onCheckedChange = { vm.toggleRepost(account.id) },
                colors = CheckboxDefaults.colors(checkedColor = Palette.amber, checkmarkColor = Palette.contactBlack, uncheckedColor = c.muted),
            )
            Chop(account, 26.dp)
            Text(account.name, style = Type.bodyDense, color = c.text, modifier = Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis)
            if (account.id in options.existingRepostAccountIds) Slug(stringResource(R.string.schedule_already))
            if (!account.hasSigner) Slug(stringResource(R.string.no_signer))
        }
    }
    val count = ui.reposts.size
    Text(
        if (count == 0) stringResource(R.string.schedule_reposts_none)
        else pluralStringResource(R.plurals.schedule_reposts_selected, count, count, count + 1),
        style = Type.small, color = c.legend,
    )

    if (count > 0) {
        OutlinedTextField(
            ui.maxDelay, vm::setMaxDelay,
            label = { Text(stringResource(R.string.schedule_max_delay)) },
            singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
            textStyle = Type.readout.copy(color = c.text),
            modifier = Modifier.fillMaxWidth(),
        )
        Text(stringResource(R.string.schedule_max_delay_help), style = Type.small, color = c.muted)
    }
}
