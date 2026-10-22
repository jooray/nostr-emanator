package today.cypherpunk.emanator.ui.screens.posts

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.Share
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.LifecycleEventEffect
import androidx.lifecycle.viewModelScope
import androidx.navigation.NavHostController
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.launch
import today.cypherpunk.emanator.AppContainer
import today.cypherpunk.emanator.R
import today.cypherpunk.emanator.data.ApiException
import today.cypherpunk.emanator.data.Loadable
import today.cypherpunk.emanator.data.PostItem
import today.cypherpunk.emanator.data.PostResponse
import today.cypherpunk.emanator.data.cachedFlow
import today.cypherpunk.emanator.ui.LocalContainer
import today.cypherpunk.emanator.ui.Routes
import today.cypherpunk.emanator.ui.appViewModel
import today.cypherpunk.emanator.ui.components.AlarmBlock
import today.cypherpunk.emanator.ui.components.ConsoleScaffold
import today.cypherpunk.emanator.ui.components.ElapsedReadout
import today.cypherpunk.emanator.ui.components.Gutter
import today.cypherpunk.emanator.ui.components.Identity
import today.cypherpunk.emanator.ui.components.Legend
import today.cypherpunk.emanator.ui.components.LoadableContent
import today.cypherpunk.emanator.ui.components.NoteBlock
import today.cypherpunk.emanator.ui.components.PollStrip
import today.cypherpunk.emanator.ui.components.PrimaryButton
import today.cypherpunk.emanator.ui.components.RichContent
import today.cypherpunk.emanator.ui.components.Rule
import today.cypherpunk.emanator.ui.components.SecondaryButton
import today.cypherpunk.emanator.ui.components.SlugButton
import today.cypherpunk.emanator.ui.components.SlugTone
import today.cypherpunk.emanator.ui.components.StatusSlug
import today.cypherpunk.emanator.ui.components.WaitBlock
import today.cypherpunk.emanator.ui.components.rememberSnackbar
import today.cypherpunk.emanator.ui.theme.LocalConsole
import today.cypherpunk.emanator.ui.theme.Type
import today.cypherpunk.emanator.util.Links
import today.cypherpunk.emanator.util.Times
import java.time.Duration
import java.time.Instant

private val InFlight = setOf("awaiting_signature", "pending_signature", "publishing")

/**
 * One post (web: posts/show with its signing, publishing and reposts panels).
 * While anything is with the signer or on its way to relays, the screen polls
 * so the operator watches it land.
 */
class PostViewModel(private val container: AppContainer, private val id: Long) : ViewModel() {
    val state = MutableStateFlow(Loadable<PostResponse>())
    private val _messages = MutableSharedFlow<String>(extraBufferCapacity = 4)
    val messages = _messages.asSharedFlow()
    /** Set after reschedule: go to the schedule screen with these reposts preselected. */
    val rescheduled = MutableSharedFlow<List<Long>>(extraBufferCapacity = 1)
    val deleted = MutableStateFlow(false)
    val busy = MutableStateFlow(false)
    private var job: Job? = null
    private var poller: Job? = null

    /** Set by the screen; polling runs only while the post is on screen. */
    @Volatile var onScreen = false
        set(value) {
            field = value
            if (value) ensurePolling() else poller?.cancel()
        }

    init { refresh() }

    fun refresh() {
        job?.cancel()
        job = viewModelScope.launch {
            cachedFlow(container.cache, "post:$id", PostResponse.serializer()) { container.api.post(id) }
                .collect {
                    state.value = it
                    if (!it.loading) ensurePolling()
                }
        }
    }

    private fun inFlight(post: PostItem?) =
        post != null && (post.status in InFlight || post.reposts.any { it.status in InFlight })

    /** Polls every 3 s while something is with the signer or the relays. */
    private fun ensurePolling() {
        if (!onScreen || !inFlight(state.value.data?.post) || poller?.isActive == true) return
        poller = viewModelScope.launch {
            while (inFlight(state.value.data?.post)) {
                delay(3000)
                try {
                    val fresh = container.api.post(id)
                    container.cache.write("post:$id", PostResponse.serializer(), fresh)
                    state.value = Loadable(data = fresh)
                } catch (e: ApiException) {
                    if (!e.isNetwork) break
                }
            }
            refreshBadges(container)
        }
    }

    private fun act(block: suspend () -> PostResponse?) {
        viewModelScope.launch {
            busy.value = true
            try {
                val response = block()
                if (response != null) {
                    state.value = Loadable(data = response)
                    container.cache.write("post:$id", PostResponse.serializer(), response)
                    response.message?.let { _messages.emit(it) }
                }
                ensurePolling()
                refreshBadges(container)
            } catch (e: ApiException) {
                _messages.emit(e.message)
            } finally {
                busy.value = false
            }
        }
    }

    fun postAction(action: String) = act { container.api.postAction(id, action) }

    fun reschedule() {
        viewModelScope.launch {
            busy.value = true
            try {
                val response = container.api.postAction(id, "reschedule")
                state.value = Loadable(data = response)
                rescheduled.emit(response.repostAccountIds)
            } catch (e: ApiException) {
                _messages.emit(e.message)
            } finally {
                busy.value = false
            }
        }
    }

    fun repostAction(repostId: Long, action: String) = act { container.api.repostAction(id, repostId, action) }
    fun cancelRepost(repostId: Long) = act { container.api.cancelRepost(id, repostId) }

    fun delete() {
        viewModelScope.launch {
            try {
                container.api.deletePost(id)
                refreshBadges(container)
                deleted.value = true
            } catch (e: ApiException) {
                _messages.emit(e.message)
            }
        }
    }
}

private sealed interface Confirm {
    data object Delete : Confirm
    data object Cancel : Confirm
    data object Reschedule : Confirm
    data class CancelRepost(val id: Long) : Confirm
    data class RepostNow(val id: Long) : Confirm
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
fun PostScreen(nav: NavHostController, id: Long) {
    val vm = appViewModel(key = "post:$id") { PostViewModel(it, id) }
    val state by vm.state.collectAsState()
    val deleted by vm.deleted.collectAsState()
    val busy by vm.busy.collectAsState()
    val snackbar = rememberSnackbar()
    val scope = rememberCoroutineScope()
    val container = LocalContainer.current
    val me by container.me.collectAsState()
    val context = LocalContext.current
    val c = LocalConsole.current
    var confirm by remember { mutableStateOf<Confirm?>(null) }
    var showHistory by rememberSaveable { mutableStateOf(false) }

    LaunchedEffect(Unit) { vm.messages.collect { snackbar.showSnackbar(it) } }
    LaunchedEffect(Unit) { vm.rescheduled.collect { nav.navigate(Routes.schedule(id, it)) } }
    LaunchedEffect(deleted) { if (deleted) nav.popBackStack() }
    LifecycleEventEffect(Lifecycle.Event.ON_RESUME) { vm.onScreen = true; vm.refresh() }
    LifecycleEventEffect(Lifecycle.Event.ON_PAUSE) { vm.onScreen = false }

    val post = state.data?.post

    ConsoleScaffold(
        title = stringResource(R.string.post_title),
        onBack = { nav.popBackStack() },
        snackbar = snackbar,
        actions = {
            if (post != null) {
                IconButton(onClick = { Links.copy(context, "post", post.content.orEmpty()) }) {
                    Icon(Icons.Filled.ContentCopy, contentDescription = stringResource(R.string.post_copy_text), tint = c.legend)
                }
                IconButton(onClick = { Links.share(context, post.content.orEmpty()) }) {
                    Icon(Icons.Filled.Share, contentDescription = stringResource(R.string.action_share), tint = c.legend)
                }
            }
        },
    ) { padding ->
        LoadableContent(state, onRefresh = vm::refresh, modifier = Modifier.padding(padding)) { response ->
            val p = response.post
            Column(
                Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(Gutter),
                verticalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Identity(p.account, Modifier.weight(1f), size = 28.dp)
                    StatusSlug(p.status)
                }
                Stamps(p, onOpenParent = { Links.openNostr(context, p.replyToNevent, p.replyToViewerUrl) })
                RichContent(p.content, p.references)
                Rule()

                SigningPanel(p, onAskAgain = { vm.postAction("retry_sign") })
                PublishPanel(
                    p,
                    onRetryPublish = { vm.postAction(if (p.can.retryPublish) "retry_publish" else "retry_sign") },
                    onRebroadcast = { vm.postAction("rebroadcast") },
                )

                if (p.reposts.isNotEmpty()) {
                    Legend(stringResource(R.string.reposts_title))
                    p.reposts.forEach { repost ->
                        RepostRow(
                            repost,
                            onCancel = { confirm = Confirm.CancelRepost(repost.id) },
                            onRetrySign = { vm.repostAction(repost.id, "retry_sign") },
                            onRebroadcast = { vm.repostAction(repost.id, "rebroadcast") },
                            onPublishNow = { confirm = Confirm.RepostNow(repost.id) },
                        )
                    }
                }

                if (p.versionHistory.isNotEmpty()) {
                    Legend(
                        "${stringResource(R.string.post_version_history)} · ${p.versionHistory.size}",
                        Modifier.clickable { showHistory = !showHistory },
                    )
                    if (showHistory) {
                        p.versionHistory.asReversed().forEach { version ->
                            Column(Modifier.fillMaxWidth()) {
                                Text(Times.dateTime(Times.parse(version.changedAt)), style = Type.mono, color = c.muted)
                                Text(version.content, style = Type.small, color = c.legend)
                            }
                        }
                    }
                }

                Legend(stringResource(R.string.post_actions))
                if (p.can.schedule) {
                    PrimaryButton(stringResource(R.string.post_schedule), { nav.navigate(Routes.schedule(p.id)) }, Modifier.fillMaxWidth())
                }
                FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    if (p.can.edit) SecondaryButton(stringResource(R.string.post_edit), { nav.navigate(Routes.compose(post = p.id)) }, enabled = !busy)
                    if (p.can.reschedule) SecondaryButton(stringResource(R.string.post_reschedule), { confirm = Confirm.Reschedule }, enabled = !busy)
                    if (p.can.cancel) SecondaryButton(stringResource(R.string.post_cancel_schedule), { confirm = Confirm.Cancel }, enabled = !busy)
                    if (p.nevent != null || p.viewerUrl != null) {
                        SecondaryButton(stringResource(R.string.action_open_in_client), { Links.openNostr(context, p.nevent, p.viewerUrl) })
                    }
                    p.nevent?.let { nevent ->
                        SecondaryButton(stringResource(R.string.action_copy_nevent), { Links.copy(context, "nevent", nevent) })
                    }
                    // Optional in settings (web: users/edit): Emanator does not
                    // hand notes to other networks unless asked. Copy and the
                    // generic share icon are in the header and stay untouched.
                    val sharing = me?.user?.settings
                    val text = p.content?.trim().orEmpty()
                    if (sharing?.xShare == true && text.isNotEmpty()) {
                        SecondaryButton(stringResource(R.string.post_share_on_x), { Links.composeX(context, text) })
                    }
                    // Facebook and LinkedIn take no text from a URL: into their app
                    // when it is installed, otherwise copied + their site open.
                    val copiedNotice = context.getString(R.string.post_share_copied)
                    if (sharing?.facebookShare == true && text.isNotEmpty()) {
                        SecondaryButton(stringResource(R.string.post_share_on_facebook), {
                            if (!Links.shareTextTo(context, Links.FACEBOOK_PACKAGE, text, Links.FACEBOOK_WEB)) {
                                scope.launch { snackbar.showSnackbar(copiedNotice) }
                            }
                        })
                    }
                    if (sharing?.linkedinShare == true && text.isNotEmpty()) {
                        SecondaryButton(stringResource(R.string.post_share_on_linkedin), {
                            if (!Links.shareTextTo(context, Links.LINKEDIN_PACKAGE, text, Links.LINKEDIN_WEB)) {
                                scope.launch { snackbar.showSnackbar(copiedNotice) }
                            }
                        })
                    }
                    SecondaryButton(stringResource(R.string.post_delete), { confirm = Confirm.Delete }, danger = true, enabled = !busy)
                }
            }
        }
    }

    confirm?.let { which ->
        val (text, label) = when (which) {
            Confirm.Delete -> stringResource(R.string.post_delete_confirm) to stringResource(R.string.post_delete)
            Confirm.Cancel -> stringResource(R.string.post_cancel_confirm) to stringResource(R.string.post_cancel_schedule)
            Confirm.Reschedule -> stringResource(R.string.post_reschedule_confirm) to stringResource(R.string.post_reschedule)
            is Confirm.CancelRepost -> stringResource(R.string.reposts_cancel_confirm) to stringResource(R.string.action_confirm)
            is Confirm.RepostNow -> stringResource(R.string.reposts_repost_now_confirm) to stringResource(R.string.reposts_repost_now)
        }
        ConfirmDialog(
            text = text,
            confirmLabel = label,
            danger = which is Confirm.Delete || which is Confirm.Cancel || which is Confirm.CancelRepost,
            onDismiss = { confirm = null },
            onConfirm = {
                when (which) {
                    Confirm.Delete -> vm.delete()
                    Confirm.Cancel -> vm.postAction("cancel")
                    Confirm.Reschedule -> vm.reschedule()
                    is Confirm.CancelRepost -> vm.cancelRepost(which.id)
                    is Confirm.RepostNow -> vm.repostAction(which.id, "publish_now")
                }
            },
        )
    }
}

@Composable
private fun Stamps(p: PostItem, onOpenParent: () -> Unit) {
    val c = LocalConsole.current
    val scheduled = Times.parse(p.scheduledAt)
    val published = Times.parse(p.publishedAt)
    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
        if (published != null) {
            Text(stringResource(R.string.post_published_at, Times.dateTime(published)), style = Type.mono, color = c.legend)
        } else if (scheduled != null) {
            Text(stringResource(R.string.post_scheduled_for, Times.dateTime(scheduled)), style = Type.mono, color = c.legend)
        }
        // A reply has no other trace on this screen; without it a failed reply
        // looks like a standalone note.
        if (p.isReply && (p.replyToNevent != null || p.replyToViewerUrl != null)) {
            Text(
                stringResource(R.string.post_in_reply_to),
                Modifier.clickable(onClick = onOpenParent),
                style = Type.mono,
                color = c.amberText,
            )
        }
    }
}

/** While the signer has it: how long it has waited, and a way to ask again. */
@Composable
private fun SigningPanel(p: PostItem, onAskAgain: () -> Unit) {
    when (p.status) {
        "awaiting_signature" -> {
            val since = Times.parse(p.updatedAt)
            val stale = since != null && Duration.between(since.toInstant(), Instant.now()).toMinutes() >= 2
            WaitBlock(stringResource(if (stale) R.string.signing_past_two_minutes else R.string.post_approve_in_signer)) {
                ElapsedReadout(p.updatedAt)
            }
            if (p.can.retrySign) SlugButton(stringResource(R.string.signing_ask_again), onAskAgain, tone = SlugTone.Wait)
        }
        "failed" -> if (p.can.retrySign && !p.can.retryPublish) {
            AlarmBlock(p.error ?: stringResource(R.string.signing_no_signature)) {
                SlugButton(stringResource(R.string.signing_ask_again), onAskAgain, tone = SlugTone.Short)
            }
        }
        "scheduled" -> NoteBlock(
            if (Times.parse(p.scheduledAt)?.toInstant()?.isBefore(Instant.now()) == true) {
                stringResource(R.string.publish_due_now_explanation)
            } else {
                stringResource(R.string.signing_signed_and_held)
            },
        )
    }
}

/** On its way to relays, or what came back from them. */
@Composable
private fun PublishPanel(p: PostItem, onRetryPublish: () -> Unit, onRebroadcast: () -> Unit) {
    val c = LocalConsole.current
    when {
        p.status == "publishing" -> WaitBlock(stringResource(R.string.publish_sending, p.account?.name.orEmpty()))
        p.status == "failed" && p.can.retryPublish -> AlarmBlock(
            p.error ?: if (p.delivery.total > 0) {
                pluralStringResource(R.plurals.publish_none_accepted, p.delivery.total, p.delivery.total)
            } else {
                stringResource(R.string.publish_never_reached)
            },
        ) { SlugButton(stringResource(R.string.publish_try_again), onRetryPublish, tone = SlugTone.Short) }
    }

    if (p.delivery.total > 0) {
        Legend(stringResource(R.string.post_relays))
        PollStrip(p.delivery)
        if (p.delivery.short) {
            val missed = p.delivery.results.filter { it.result != "ok" }.joinToString(", ") { it.relay.removePrefix("wss://") }
            Text(stringResource(R.string.publish_partial_explanation, missed), style = Type.small, color = c.muted)
            if (p.can.rebroadcast) {
                SlugButton(stringResource(R.string.publish_rebroadcast), onRebroadcast, tone = if (p.delivery.alarming) SlugTone.Short else SlugTone.Plain)
            }
        }
        RelayResults(p)
    }
}

@Composable
private fun RelayResults(item: PostItem) {
    val c = LocalConsole.current
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        item.delivery.results.forEach { r ->
            val ok = r.result == "ok"
            Row(verticalAlignment = Alignment.Top) {
                Text(r.relay.removePrefix("wss://"), style = Type.mono, color = c.legend, modifier = Modifier.weight(1f))
                Text(
                    if (ok) stringResource(R.string.publish_accepted) else r.result,
                    style = Type.mono,
                    color = if (ok) c.muted else if (item.delivery.alarming) c.redText else c.legend,
                    modifier = Modifier.weight(1f).padding(start = 8.dp),
                )
            }
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun RepostRow(
    repost: PostItem,
    onCancel: () -> Unit,
    onRetrySign: () -> Unit,
    onRebroadcast: () -> Unit,
    onPublishNow: () -> Unit,
) {
    val c = LocalConsole.current
    var details by rememberSaveable(repost.id) { mutableStateOf(false) }
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Identity(repost.account, Modifier.weight(1f))
            StatusSlug(repost.status)
        }
        val stamp = Times.parse(repost.publishedAt ?: repost.scheduledAt)
        if (stamp != null) Text(Times.dateTime(stamp), style = Type.mono, color = c.muted)
        if (repost.status == "awaiting_signature") ElapsedReadout(repost.updatedAt)
        repost.error?.let { Text(it, style = Type.mono, color = c.redText) }
        if (repost.delivery.total > 0) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                PollStrip(repost.delivery, Modifier.weight(1f))
                SlugButton(stringResource(R.string.reposts_relay_details), { details = !details })
            }
            if (details) RelayResults(repost)
        }
        FlowRow(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            if (repost.can.retrySign) SlugButton(stringResource(R.string.reposts_retry_signing), onRetrySign, tone = SlugTone.Wait)
            if (repost.can.publishNow) SlugButton(stringResource(R.string.reposts_repost_now), onPublishNow)
            if (repost.can.rebroadcast) SlugButton(stringResource(R.string.reposts_rebroadcast), onRebroadcast)
            if (repost.can.cancel) SlugButton(stringResource(R.string.action_cancel), onCancel, tone = SlugTone.Short)
        }
        Rule()
    }
}
