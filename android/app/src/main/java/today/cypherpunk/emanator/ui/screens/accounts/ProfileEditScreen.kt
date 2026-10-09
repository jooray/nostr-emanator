package today.cypherpunk.emanator.ui.screens.accounts

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import androidx.navigation.NavHostController
import coil3.compose.AsyncImage
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import today.cypherpunk.emanator.AppContainer
import today.cypherpunk.emanator.R
import today.cypherpunk.emanator.data.ApiException
import today.cypherpunk.emanator.data.ProfileUpdateStatus
import today.cypherpunk.emanator.ui.Routes
import today.cypherpunk.emanator.ui.appViewModel
import today.cypherpunk.emanator.ui.components.AlarmBlock
import today.cypherpunk.emanator.ui.components.Avatar
import today.cypherpunk.emanator.ui.components.ConsoleScaffold
import today.cypherpunk.emanator.ui.components.ErrorState
import today.cypherpunk.emanator.ui.components.Gutter
import today.cypherpunk.emanator.ui.components.Legend
import today.cypherpunk.emanator.ui.components.NoteBlock
import today.cypherpunk.emanator.ui.components.PrimaryButton
import today.cypherpunk.emanator.ui.components.Rule
import today.cypherpunk.emanator.ui.components.SecondaryButton
import today.cypherpunk.emanator.ui.components.WaitBlock
import today.cypherpunk.emanator.ui.theme.LocalConsole
import today.cypherpunk.emanator.ui.theme.Palette
import today.cypherpunk.emanator.ui.theme.Type
import androidx.compose.material3.CircularProgressIndicator

/**
 * The Nostr profile (kind 0) editor. Amber has no profile editor, so this is
 * the only place a paired account's published profile can be changed.
 *
 * It starts from the profile live on relays, sends only the fields the user
 * changed (the server keeps every other field already published), and then
 * waits on the signer: publishing blocks on an Amber approval, so the request
 * is queued and its status polled.
 */
class ProfileEditViewModel(private val container: AppContainer, private val id: Long) : ViewModel() {
    data class State(
        val loading: Boolean = true,
        val loadError: ApiException? = null,
        val capable: Boolean = true,
        val fields: List<String> = emptyList(),
        val original: Map<String, String> = emptyMap(),
        val values: Map<String, String> = emptyMap(),
        val update: ProfileUpdateStatus? = null,
        val publishError: String? = null,
        val published: Boolean = false,
    ) {
        val publishing get() = update != null && update.status != "completed" && update.status != "failed"
        val changed get() = values.filter { (k, v) -> original[k].orEmpty() != v }
    }

    val state = MutableStateFlow(State())
    private var poller: Job? = null

    init { load() }

    fun load() = viewModelScope.launch {
        state.value = state.value.copy(loading = true, loadError = null)
        try {
            val profile = container.api.profile(id)
            val original = profile.editableFields.associateWith { field ->
                (profile.profile[field] as? JsonPrimitive)?.contentOrNull.orEmpty()
            }
            state.value = state.value.copy(
                loading = false, capable = profile.capable, fields = profile.editableFields,
                original = original, values = original,
            )
            profile.pending?.let { pending -> pending.id?.let { poll(it, pending) } }
        } catch (e: ApiException) {
            state.value = state.value.copy(loading = false, loadError = e)
        }
    }

    fun edit(field: String, value: String) {
        state.value = state.value.copy(values = state.value.values + (field to value), published = false)
    }

    fun publish() {
        val changes = state.value.changed
        if (changes.isEmpty()) return
        viewModelScope.launch {
            state.value = state.value.copy(publishError = null, published = false)
            try {
                val update = container.api.publishProfile(id, changes)
                update.id?.let { poll(it, update) }
            } catch (e: ApiException) {
                state.value = state.value.copy(publishError = e.message)
            }
        }
    }

    private fun poll(updateId: Long, first: ProfileUpdateStatus) {
        poller?.cancel()
        state.value = state.value.copy(update = first)
        poller = viewModelScope.launch {
            var current = first
            while (current.status != "completed" && current.status != "failed") {
                delay(1500)
                current = try {
                    container.api.profileStatus(id, updateId)
                } catch (e: ApiException) {
                    if (e.isNetwork) continue else ProfileUpdateStatus(status = "failed", error = e.message)
                }
                state.value = state.value.copy(update = current)
            }
            if (current.status == "completed") {
                state.value = state.value.copy(update = null, published = true, original = state.value.values)
            } else {
                state.value = state.value.copy(update = null, publishError = current.error)
            }
        }
    }
}

private data class FieldSpec(val key: String, val label: Int, val help: Int? = null, val multiline: Boolean = false, val keyboard: KeyboardType = KeyboardType.Text)

private val Sections = listOf(
    R.string.acc_profile_identity to listOf(
        FieldSpec("display_name", R.string.acc_profile_display_name, R.string.acc_profile_display_name_help),
        FieldSpec("name", R.string.acc_profile_handle, R.string.acc_profile_handle_help),
        FieldSpec("about", R.string.acc_profile_bio, multiline = true),
    ),
    R.string.acc_profile_images to listOf(
        FieldSpec("picture", R.string.acc_profile_avatar, R.string.acc_profile_avatar_help, keyboard = KeyboardType.Uri),
        FieldSpec("banner", R.string.acc_profile_banner, R.string.acc_profile_banner_help, keyboard = KeyboardType.Uri),
    ),
    R.string.acc_profile_links to listOf(
        FieldSpec("website", R.string.acc_profile_website, keyboard = KeyboardType.Uri),
        FieldSpec("nip05", R.string.acc_profile_nip05, R.string.acc_profile_nip05_help, keyboard = KeyboardType.Email),
        FieldSpec("lud16", R.string.acc_profile_lightning, keyboard = KeyboardType.Email),
    ),
)

@Composable
fun ProfileEditScreen(nav: NavHostController, id: Long) {
    val vm = appViewModel("profile-$id") { ProfileEditViewModel(it, id) }
    val state by vm.state.collectAsState()
    val c = LocalConsole.current

    ConsoleScaffold(stringResource(R.string.acc_profile_title), onBack = { nav.popBackStack() }) { padding ->
        when {
            state.loading -> Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(color = Palette.amber, strokeWidth = 2.dp)
            }
            state.loadError != null -> Box(Modifier.padding(padding)) { ErrorState(state.loadError!!) { vm.load() } }
            else -> Column(
                Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState()).imePadding().padding(Gutter),
                verticalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                Text(stringResource(R.string.acc_profile_intro), style = Type.small, color = c.muted)
                if (!state.capable) {
                    NoteBlock(stringResource(R.string.acc_profile_needs_repair))
                    SecondaryButton(stringResource(R.string.acc_profile_re_pair), { nav.navigate(Routes.pair(id)) }, Modifier.fillMaxWidth())
                }

                Preview(state.values)

                val enabled = state.capable && !state.publishing
                Sections.forEach { (title, specs) ->
                    Rule()
                    Legend(stringResource(title))
                    specs.filter { it.key in state.fields }.forEach { spec ->
                        Field(
                            stringResource(spec.label), state.values[spec.key].orEmpty(), { vm.edit(spec.key, it) },
                            help = spec.help?.let { stringResource(it) },
                            singleLine = !spec.multiline, minLines = if (spec.multiline) 4 else 1,
                            keyboardType = spec.keyboard, enabled = enabled,
                        )
                    }
                }
                Text(stringResource(R.string.acc_profile_unmodelled), style = Type.small, color = c.muted)

                state.update?.let { WaitBlock(it.step ?: stringResource(R.string.acc_profile_working)) }
                state.publishError?.let { AlarmBlock(it) }
                if (state.published) NoteBlock(stringResource(R.string.acc_profile_published))

                PrimaryButton(
                    stringResource(R.string.acc_profile_publish), vm::publish, Modifier.fillMaxWidth(),
                    enabled = enabled && state.changed.isNotEmpty(), busy = state.publishing,
                )
            }
        }
    }
}

/** Roughly how clients show it: the banner, the round avatar over it, the names. */
@Composable
private fun Preview(values: Map<String, String>) {
    val c = LocalConsole.current
    Column(Modifier.fillMaxWidth()) {
        Box(Modifier.fillMaxWidth().height(110.dp).background(c.panelHi)) {
            values["banner"]?.takeIf { it.startsWith("http") }?.let {
                AsyncImage(it, contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
            }
        }
        Row(Modifier.padding(horizontal = 12.dp).offset(y = (-28).dp), verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            val name = values["display_name"]?.ifBlank { null } ?: values["name"]?.ifBlank { null }
            Avatar(values["picture"]?.takeIf { it.startsWith("http") }, name ?: "?", 64.dp, ink = Palette.neutral500)
            Column(Modifier.padding(bottom = 4.dp)) {
                Text(name ?: "—", style = Type.title, color = c.text)
                values["name"]?.takeIf { it.isNotBlank() }?.let { Text("@$it", style = Type.small, color = c.muted) }
            }
        }
    }
}
