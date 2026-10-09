package today.cypherpunk.emanator.ui.screens.settings

import androidx.activity.compose.LocalActivity
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.navigation.NavHostController
import kotlinx.coroutines.launch
import today.cypherpunk.emanator.AppContainer
import today.cypherpunk.emanator.BuildConfig
import today.cypherpunk.emanator.R
import today.cypherpunk.emanator.data.ApiException
import today.cypherpunk.emanator.data.Billing
import today.cypherpunk.emanator.data.MediaSettings
import today.cypherpunk.emanator.data.User
import today.cypherpunk.emanator.ui.LocalContainer
import today.cypherpunk.emanator.ui.Routes
import today.cypherpunk.emanator.ui.appViewModel
import today.cypherpunk.emanator.ui.components.AlarmBlock
import today.cypherpunk.emanator.ui.components.Avatar
import today.cypherpunk.emanator.ui.components.ConsoleScaffold
import today.cypherpunk.emanator.ui.components.Gutter
import today.cypherpunk.emanator.ui.components.Legend
import today.cypherpunk.emanator.ui.components.PrimaryButton
import today.cypherpunk.emanator.ui.components.Readout
import today.cypherpunk.emanator.ui.components.Rule
import today.cypherpunk.emanator.ui.components.SecondaryButton
import today.cypherpunk.emanator.ui.components.SlugButton
import today.cypherpunk.emanator.ui.components.rememberSnackbar
import today.cypherpunk.emanator.ui.screens.accounts.ChoiceList
import today.cypherpunk.emanator.ui.screens.accounts.ConfirmDialog
import today.cypherpunk.emanator.ui.screens.accounts.Field
import today.cypherpunk.emanator.ui.screens.accounts.LoadVm
import today.cypherpunk.emanator.ui.screens.accounts.NavRow
import today.cypherpunk.emanator.ui.screens.accounts.shortNpub
import today.cypherpunk.emanator.ui.screens.accounts.withSnackbar
import today.cypherpunk.emanator.ui.theme.LocalConsole
import today.cypherpunk.emanator.ui.theme.Palette
import today.cypherpunk.emanator.ui.theme.Type
import today.cypherpunk.emanator.util.AppLocale
import java.time.ZoneId

/** Longest-side choices, as on the web (MediaPreferences::MAX_EDGES). */
internal val MaxEdges = listOf(0, 1280, 1600, 2048, 2560, 3840)
internal val Qualities = listOf(60, 70, 75, 80, 85, 90, 95)
internal val VideoResolutions = listOf(0, 480, 720, 1080, 1440)

/**
 * The user's settings (web: users/edit). Everything here lives on the user on
 * the server, so a change made here shows up on the web and every other phone.
 */
@Composable
fun SettingsScreen(nav: NavHostController) {
    val container = LocalContainer.current
    val activity = LocalActivity.current
    val scope = rememberCoroutineScope()
    val snackbar = rememberSnackbar()
    val me by container.me.collectAsState()
    var confirmLogout by remember { mutableStateOf(false) }

    LaunchedEffect(Unit) { runCatching { container.setMe(container.api.me()) } }

    /** PATCH /me with `changes`; the answer becomes the app's user. */
    suspend fun save(changes: Map<String, Any?>): Boolean {
        val updated = withSnackbar(snackbar) { container.api.updateMe(changes) } ?: return false
        container.setMe(updated)
        container.prefs.theme = updated.user.settings.theme
        return true
    }

    ConsoleScaffold(stringResource(R.string.set_title), onBack = { nav.popBackStack() }, snackbar = snackbar) { padding ->
        val user = me?.user
        Column(Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState()).imePadding()) {
            if (user != null) {
                ProfileSection(user) {
                    scope.launch { withSnackbar(snackbar) { container.api.refreshMyProfile() }?.message?.let { snackbar.showSnackbar(it) } }
                }

                Section(stringResource(R.string.set_language), stringResource(R.string.set_language_help)) {
                    val choice = container.prefs.locale
                    ChoiceList(
                        listOf<Pair<String?, String>>(null to stringResource(R.string.set_language_phone)) +
                            AppLocale.SUPPORTED.map { it to AppLocale.displayName(it) },
                        choice,
                        { code ->
                            AppLocale.apply(container.context, code)
                            scope.launch {
                                save(mapOf("locale" to (code ?: AppLocale.current(container.context))))
                                activity?.recreate()
                            }
                        },
                    )
                }

                Section(stringResource(R.string.set_theme)) {
                    ChoiceList(
                        listOf(
                            "system" to stringResource(R.string.set_theme_system),
                            "light" to stringResource(R.string.set_theme_light),
                            "dark" to stringResource(R.string.set_theme_dark),
                        ),
                        user.settings.theme,
                        { theme -> scope.launch { save(mapOf("theme" to theme)) } },
                    )
                }

                Section(stringResource(R.string.set_timezone)) {
                    Readout(stringResource(R.string.set_timezone), user.settings.timezone.ifBlank { ZoneId.systemDefault().id }, mono = true)
                    Text(stringResource(R.string.set_timezone_help), style = Type.small, color = LocalConsole.current.muted)
                }

                MediaSection(user.settings.media) { media -> scope.launch { save(mapOf("media" to media)) } }

                Section(stringResource(R.string.set_event_viewer), stringResource(R.string.set_event_viewer_help)) {
                    ChoiceList(
                        listOf("njump" to "njump.me", "yakihonne" to "YakiHonne"),
                        user.settings.eventViewer,
                        { viewer -> scope.launch { save(mapOf("event_viewer" to viewer)) } },
                    )
                }

                CustomRelaysSection(user) { relays, done ->
                    scope.launch {
                        try {
                            val updated = container.api.updateMe(mapOf("custom_relays" to relays))
                            container.setMe(updated)
                            done(null)
                            snackbar.showSnackbar(container.context.getString(R.string.set_saved))
                        } catch (e: ApiException) {
                            done(e.message)
                        }
                    }
                }

                if (me?.billingEnabled == true) BillingSummary(nav)
            }

            Rule()
            NavRow(stringResource(R.string.set_devices_link), { nav.navigate(Routes.DEVICES) })
            NavRow(stringResource(R.string.set_mcp_link), { nav.navigate(Routes.MCP_TOKENS) })

            Column(Modifier.padding(Gutter), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                SecondaryButton(stringResource(R.string.set_logout), { confirmLogout = true }, Modifier.fillMaxWidth(), danger = true)
                Text(
                    stringResource(R.string.set_version, BuildConfig.VERSION_NAME, container.prefs.serverUrl.removePrefix("https://")),
                    style = Type.mono, color = LocalConsole.current.muted,
                )
            }
        }
    }

    if (confirmLogout) {
        ConfirmDialog(
            stringResource(R.string.set_logout_confirm), stringResource(R.string.set_logout),
            onConfirm = { scope.launch { logOut(container) } },
            onDismiss = { confirmLogout = false },
        )
    }
}

/** Ends this device's session on the server (best effort) and forgets it locally. */
internal suspend fun logOut(container: AppContainer) {
    runCatching { container.api.logout() }
    container.signOutLocally()
}

@Composable
internal fun Section(title: String, help: String? = null, content: @Composable () -> Unit) {
    Rule()
    Column(Modifier.fillMaxWidth().padding(Gutter), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Legend(title)
        help?.let { Text(it, style = Type.small, color = LocalConsole.current.muted) }
        content()
    }
}

@Composable
private fun ProfileSection(user: User, onRefresh: () -> Unit) {
    val c = LocalConsole.current
    Column(Modifier.fillMaxWidth().padding(Gutter), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Legend(stringResource(R.string.set_profile))
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            Avatar(user.pictureUrl, user.name, 56.dp)
            Column(Modifier.weight(1f)) {
                Text(user.name, style = Type.title, color = c.text)
                Text(shortNpub(user.npub), style = Type.mono, color = c.muted)
            }
        }
        user.about?.takeIf { it.isNotBlank() }?.let { Text(it, style = Type.small, color = c.legend, maxLines = 4) }
        SlugButton(stringResource(R.string.set_refresh_profile), onRefresh)
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun MediaSection(media: MediaSettings, onChange: (Map<String, Any?>) -> Unit) {
    val c = LocalConsole.current
    fun current() = mapOf(
        "compress" to media.compress, "max_edge" to media.maxEdge, "quality" to media.quality, "photo_format" to media.photoFormat,
        "video_compress" to media.videoCompress, "video_resolution" to media.videoResolution, "video_quality" to media.videoQuality,
    )
    Section(stringResource(R.string.media_title), stringResource(R.string.media_help)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(stringResource(R.string.media_compress), style = Type.bodyDense, color = c.text, modifier = Modifier.weight(1f))
            Switch(
                checked = media.compress,
                onCheckedChange = { onChange(current() + ("compress" to it)) },
                colors = SwitchDefaults.colors(checkedTrackColor = Palette.amber, checkedThumbColor = Palette.contactBlack),
            )
        }
        val enabled = media.compress
        Text(stringResource(R.string.media_max_edge).uppercase(), style = Type.slug, color = c.muted)
        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            MaxEdges.forEach { edge ->
                Chip(
                    if (edge == 0) stringResource(R.string.media_original_size) else stringResource(R.string.media_pixels, edge),
                    media.maxEdge == edge, enabled,
                ) { onChange(current() + ("max_edge" to edge)) }
            }
        }
        Text(stringResource(R.string.media_quality).uppercase(), style = Type.slug, color = c.muted)
        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Qualities.forEach { q -> Chip("$q", media.quality == q, enabled) { onChange(current() + ("quality" to q)) } }
        }
        Text(stringResource(R.string.media_photo_format).uppercase(), style = Type.slug, color = c.muted)
        ChoiceList(
            listOf("jpeg" to stringResource(R.string.media_format_jpeg), "webp" to stringResource(R.string.media_format_webp)),
            media.photoFormat,
            { onChange(current() + ("photo_format" to it)) },
            enabled = enabled,
        )
        Text(stringResource(R.string.media_lossless_note), style = Type.small, color = c.muted)

        Legend(stringResource(R.string.media_video_title))
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(stringResource(R.string.media_video_compress), style = Type.bodyDense, color = c.text, modifier = Modifier.weight(1f))
            Switch(
                checked = media.videoCompress,
                onCheckedChange = { onChange(current() + ("video_compress" to it)) },
                colors = SwitchDefaults.colors(checkedTrackColor = Palette.amber, checkedThumbColor = Palette.contactBlack),
            )
        }
        val videoEnabled = media.videoCompress
        Text(stringResource(R.string.media_video_resolution).uppercase(), style = Type.slug, color = c.muted)
        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            VideoResolutions.forEach { res ->
                Chip(
                    if (res == 0) stringResource(R.string.media_original_size) else "${res}p",
                    media.videoResolution == res, videoEnabled,
                ) { onChange(current() + ("video_resolution" to res)) }
            }
        }
        Text(stringResource(R.string.media_video_quality).uppercase(), style = Type.slug, color = c.muted)
        ChoiceList(
            listOf(
                "small" to stringResource(R.string.media_video_quality_small),
                "balanced" to stringResource(R.string.media_video_quality_balanced),
                "high" to stringResource(R.string.media_video_quality_high),
            ),
            media.videoQuality,
            { onChange(current() + ("video_quality" to it)) },
            enabled = videoEnabled,
        )
        Text(stringResource(R.string.media_video_note), style = Type.small, color = c.muted)
    }
}

@Composable
internal fun Chip(label: String, selected: Boolean, enabled: Boolean = true, onClick: () -> Unit) {
    val c = LocalConsole.current
    FilterChip(
        selected = selected,
        onClick = onClick,
        enabled = enabled,
        label = { Text(label, style = Type.label) },
        colors = FilterChipDefaults.filterChipColors(
            selectedContainerColor = c.activeFill, selectedLabelColor = c.text, labelColor = c.legend,
        ),
    )
}

@Composable
private fun CustomRelaysSection(user: User, onSave: (List<String>, (String?) -> Unit) -> Unit) {
    var text by rememberSaveable(user.settings.customRelays) { mutableStateOf(user.settings.customRelays.joinToString("\n")) }
    var error by remember { mutableStateOf<String?>(null) }
    var saving by remember { mutableStateOf(false) }
    Section(stringResource(R.string.set_custom_relays), stringResource(R.string.set_custom_relays_help)) {
        Field(
            stringResource(R.string.set_custom_relays_label), text, { text = it },
            placeholder = "wss://relay.damus.io\nwss://nos.lol", singleLine = false, minLines = 4,
            keyboardType = KeyboardType.Uri, isError = error != null,
        )
        error?.let { AlarmBlock(it) }
        SecondaryButton(stringResource(R.string.set_custom_relays_save), {
            saving = true
            onSave(text.lines().map { it.trim() }.filter { it.isNotEmpty() }) { message ->
                error = message
                saving = false
            }
        }, enabled = !saving)
    }
}

@Composable
private fun BillingSummary(nav: NavHostController) {
    val vm = appViewModel("settings-billing") { c -> LoadVm(c.cache, "billing", Billing.serializer()) { c.api.billing() } }
    val state by vm.state.collectAsState()
    LaunchedEffect(Unit) { vm.load() }
    val billing = state.data
    Section(stringResource(R.string.bill_title)) {
        Text(billing?.let { billingNote(it) } ?: stringResource(R.string.bill_note_none), style = Type.small, color = LocalConsole.current.legend)
        PrimaryButton(stringResource(R.string.bill_note_link), { nav.navigate(Routes.BILLING) })
    }
}
