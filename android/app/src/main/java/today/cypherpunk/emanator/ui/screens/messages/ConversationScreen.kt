package today.cypherpunk.emanator.ui.screens.messages

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CheckboxDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.repeatOnLifecycle
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import androidx.navigation.NavHostController
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import today.cypherpunk.emanator.AppContainer
import today.cypherpunk.emanator.R
import today.cypherpunk.emanator.data.ApiException
import today.cypherpunk.emanator.data.Message
import today.cypherpunk.emanator.data.Person
import today.cypherpunk.emanator.data.Thread
import today.cypherpunk.emanator.ui.Routes
import today.cypherpunk.emanator.ui.appViewModel
import today.cypherpunk.emanator.ui.components.Avatar
import today.cypherpunk.emanator.ui.components.Chop
import today.cypherpunk.emanator.ui.components.ConsoleScaffold
import today.cypherpunk.emanator.ui.components.EmptyState
import today.cypherpunk.emanator.ui.components.ErrorState
import today.cypherpunk.emanator.ui.components.Gutter
import today.cypherpunk.emanator.ui.components.NoteBlock
import today.cypherpunk.emanator.ui.components.PrimaryButton
import today.cypherpunk.emanator.ui.components.RichContent
import today.cypherpunk.emanator.ui.components.Rule
import today.cypherpunk.emanator.ui.components.SavedCopyNotice
import today.cypherpunk.emanator.ui.components.SecondaryButton
import today.cypherpunk.emanator.ui.components.Slug
import today.cypherpunk.emanator.ui.components.SlugButton
import today.cypherpunk.emanator.ui.components.SlugTone
import today.cypherpunk.emanator.ui.components.WaitBlock
import today.cypherpunk.emanator.ui.components.rememberSnackbar
import today.cypherpunk.emanator.ui.theme.LocalConsole
import today.cypherpunk.emanator.ui.theme.Palette
import today.cypherpunk.emanator.ui.theme.Type
import today.cypherpunk.emanator.util.Links
import today.cypherpunk.emanator.util.Times

data class ThreadUi(
    val thread: Thread? = null,
    /** Oldest first: pages loaded with "load older", then the latest window. */
    val messages: List<Message> = emptyList(),
    val hasMore: Boolean = false,
    val loading: Boolean = false,
    val loadingOlder: Boolean = false,
    val sending: Boolean = false,
    val error: ApiException? = null,
    val fromCache: Boolean = false,
) {
    val anySending get() = messages.any { it.outbound && it.sending }
}

sealed interface ThreadEvent {
    data class Notice(val text: String) : ThreadEvent
    data class Error(val text: String) : ThreadEvent
    data class MovedTo(val conversationId: Long) : ThreadEvent
    data object Closed : ThreadEvent
    data object Sent : ThreadEvent
}

/**
 * One conversation (web: conversations#show). Reads are plain SQL on the
 * server — decryption happened in the background — so polling is cheap; it
 * speeds up while one of our own messages is still being sealed and delivered.
 */
class ConversationViewModel(private val container: AppContainer, private val id: Long) : ViewModel() {
    private val _ui = MutableStateFlow(ThreadUi())
    val ui = _ui.asStateFlow()
    private val _events = MutableSharedFlow<ThreadEvent>(extraBufferCapacity = 4)
    val events = _events.asSharedFlow()

    /** Messages fetched with "load older"; kept across refreshes of the latest window. */
    private var older: List<Message> = emptyList()
    private var olderHasMore: Boolean? = null
    private var badgesRefreshed = false
    private val cacheKey = "thread:$id"

    init {
        viewModelScope.launch {
            container.cache.read(cacheKey, Thread.serializer())?.let { cached ->
                if (_ui.value.thread == null) apply(cached, fromCache = true)
            }
        }
        refresh()
    }

    private fun apply(thread: Thread, fromCache: Boolean = false) {
        val latestIds = thread.messages.map { it.id }.toSet()
        _ui.update {
            it.copy(
                thread = thread,
                messages = older.filter { m -> m.id !in latestIds } + thread.messages,
                hasMore = olderHasMore ?: thread.hasMore,
                loading = false,
                error = null,
                fromCache = fromCache,
            )
        }
    }

    fun refresh(quiet: Boolean = false) {
        viewModelScope.launch {
            if (!quiet) _ui.update { it.copy(loading = true) }
            try {
                val thread = container.api.thread(id)
                container.cache.write(cacheKey, Thread.serializer(), thread)
                apply(thread)
                // Opening the thread marked it read on the server; move the tab badge.
                if (!badgesRefreshed) {
                    badgesRefreshed = true
                    refreshBadges(container)
                }
            } catch (e: ApiException) {
                _ui.update { it.copy(loading = false, error = e) }
            }
        }
    }

    fun loadOlder() {
        val state = _ui.value
        val oldest = state.messages.firstOrNull() ?: return
        if (state.loadingOlder || !state.hasMore) return
        viewModelScope.launch {
            _ui.update { it.copy(loadingOlder = true) }
            try {
                val page = container.api.thread(id, before = oldest.id)
                older = (page.messages + older).distinctBy { it.id }
                olderHasMore = page.hasMore
                _ui.update {
                    val known = it.messages.map { m -> m.id }.toSet()
                    it.copy(messages = page.messages.filter { m -> m.id !in known } + it.messages,
                        hasMore = page.hasMore, loadingOlder = false)
                }
            } catch (e: ApiException) {
                _ui.update { it.copy(loadingOlder = false) }
                _events.tryEmit(ThreadEvent.Error(e.message))
            }
        }
    }

    fun send(content: String, replyTo: String?, legacyAck: Boolean) {
        if (content.isBlank() || _ui.value.sending) return
        viewModelScope.launch {
            _ui.update { it.copy(sending = true) }
            try {
                val sent = container.api.sendMessage(id, content.trim(), replyTo, legacyAck)
                _ui.update { it.copy(sending = false) }
                _events.tryEmit(ThreadEvent.Sent)
                val target = sent.conversationId ?: sent.message.conversationId
                if (target != id) {
                    _events.tryEmit(ThreadEvent.MovedTo(target))
                } else {
                    _ui.update { it.copy(messages = (it.messages.filter { m -> m.id != sent.message.id }) + sent.message) }
                    refresh(quiet = true)
                }
            } catch (e: ApiException) {
                _ui.update { it.copy(sending = false) }
                _events.tryEmit(ThreadEvent.Error(e.message))
            }
        }
    }

    fun retry(message: Message) = act { container.api.retryMessage(message.id).also { refresh(quiet = true) } }

    /** Resend a failed private message as an acknowledged legacy one. */
    fun downgrade(message: Message) = act {
        val sent = container.api.downgradeMessage(message.id)
        val target = sent.conversationId ?: sent.message.conversationId
        if (target != id) _events.tryEmit(ThreadEvent.MovedTo(target)) else refresh(quiet = true)
    }

    fun accept() = act {
        val result = container.api.acceptConversation(id)
        _ui.update { it.copy(thread = it.thread?.copy(conversation = result.conversation)) }
        result.message?.let { _events.tryEmit(ThreadEvent.Notice(it)) }
        refreshBadges(container)
    }

    fun block() = act {
        container.api.blockConversation(id)
        refreshBadges(container)
        _events.tryEmit(ThreadEvent.Closed)
    }

    private fun act(block: suspend () -> Unit) {
        viewModelScope.launch {
            try {
                block()
            } catch (e: ApiException) {
                _events.tryEmit(ThreadEvent.Error(e.message))
            }
        }
    }
}

@Composable
fun ConversationScreen(nav: NavHostController, id: Long) {
    val vm = appViewModel(key = "conversation-$id") { ConversationViewModel(it, id) }
    val ui by vm.ui.collectAsState()
    val c = LocalConsole.current
    val snackbar = rememberSnackbar()
    val currentUi by rememberUpdatedState(ui)
    var replyTo by remember { mutableStateOf<Message?>(null) }
    var draft by rememberSaveable { mutableStateOf("") }
    var confirmBlock by remember { mutableStateOf(false) }

    LaunchedEffect(Unit) {
        vm.events.collect { event ->
            when (event) {
                is ThreadEvent.Notice -> snackbar.showSnackbar(event.text)
                is ThreadEvent.Error -> snackbar.showSnackbar(event.text)
                is ThreadEvent.MovedTo -> nav.navigate(Routes.conversation(event.conversationId)) {
                    popUpTo(Routes.CONVERSATION) { inclusive = true }
                }
                ThreadEvent.Closed -> nav.popBackStack()
                ThreadEvent.Sent -> { draft = ""; replyTo = null }
            }
        }
    }
    // Fast while our own message is being sealed and delivered, a little faster
    // while their DM inbox is still being looked up, and gentle otherwise.
    val lifecycle = androidx.lifecycle.compose.LocalLifecycleOwner.current.lifecycle
    LaunchedEffect(lifecycle) {
        // Only while on screen: a background poll would mark incoming messages
        // read nobody has seen, and drain the battery.
        lifecycle.repeatOnLifecycle(Lifecycle.State.RESUMED) {
            while (true) {
                val wait = when {
                    currentUi.anySending -> 4_000L
                    currentUi.thread?.delivery == "checking" -> 5_000L
                    else -> 15_000L
                }
                delay(wait)
                vm.refresh(quiet = true)
            }
        }
    }

    val thread = ui.thread
    ConsoleScaffold(
        thread?.conversation?.title ?: stringResource(R.string.conv_title),
        onBack = { nav.popBackStack() },
        snackbar = snackbar,
    ) { padding ->
        Column(Modifier.fillMaxSize().padding(padding).imePadding()) {
            if (ui.loading) LinearProgressIndicator(Modifier.fillMaxWidth().height(2.dp), color = Palette.amber, trackColor = Color.Transparent)
            if (thread == null) {
                if (ui.error != null) ErrorState(ui.error!!) { vm.refresh() }
                else Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator(color = Palette.amber, strokeWidth = 2.dp)
                }
                return@Column
            }
            ui.error?.let { if (!it.isUnauthorized) SavedCopyNotice(it) }

            ThreadHeader(thread)

            val listState = rememberLazyListState()
            LaunchedEffect(ui.messages.lastOrNull()?.id) { listState.animateScrollToItem(0) }
            val byRumor = remember(ui.messages) { ui.messages.filter { it.rumorId != null }.associateBy { it.rumorId } }

            LazyColumn(
                Modifier.weight(1f).fillMaxWidth(),
                state = listState,
                reverseLayout = true,
                verticalArrangement = Arrangement.spacedBy(10.dp),
                contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = Gutter, vertical = 12.dp),
            ) {
                if (ui.messages.isEmpty()) {
                    item { EmptyState(stringResource(R.string.conv_empty)) }
                }
                items(ui.messages.asReversed(), key = { it.id }) { message ->
                    Bubble(
                        message = message,
                        showSender = thread.conversation.group && !message.outbound,
                        quoted = message.replyToRumorId?.let { byRumor[it] },
                        canReply = !thread.conversation.legacy && message.rumorId != null,
                        risks = thread.legacyDowngradeRisks,
                        onReply = { replyTo = message },
                        onRetry = { vm.retry(message) },
                        onDowngrade = { vm.downgrade(message) },
                    )
                }
                if (ui.hasMore) {
                    item {
                        Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                            if (ui.loadingOlder) CircularProgressIndicator(Modifier.size(20.dp), color = Palette.amber, strokeWidth = 2.dp)
                            else SlugButton(stringResource(R.string.conv_load_older), vm::loadOlder)
                        }
                    }
                }
            }

            Rule()
            if (thread.conversation.classification == "request") {
                RequestBar(onAccept = vm::accept, onBlock = { confirmBlock = true })
            } else {
                Composer(
                    thread = thread,
                    draft = draft,
                    onDraft = { draft = it },
                    replyTo = replyTo,
                    onClearReply = { replyTo = null },
                    sending = ui.sending,
                    onSend = { legacyAck -> vm.send(draft, replyTo?.rumorId, legacyAck) },
                    onEnableMessaging = { thread.conversation.account?.let { nav.navigate(Routes.pair(it.id, "messaging")) } },
                )
            }
        }
    }

    if (confirmBlock) {
        ConfirmDialog(
            stringResource(R.string.conv_block_confirm),
            stringResource(R.string.conv_block),
            onConfirm = vm::block,
            onDismiss = { confirmBlock = false },
        )
    }
}

/** Both sides, explicitly: with one inbox across identities, "which of mine?" must never need inferring. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun ThreadHeader(thread: Thread) {
    val c = LocalConsole.current
    val context = LocalContext.current
    val conversation = thread.conversation
    val peers = conversation.peers
    Column(Modifier.fillMaxWidth().padding(horizontal = Gutter, vertical = 10.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Chop(conversation.account, 24.dp)
            Text(conversation.account?.name.orEmpty().uppercase(), style = Type.label, color = c.legend, maxLines = 1,
                overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false))
            Text("↔", style = Type.label, color = c.muted)
            if (peers.isEmpty()) {
                Text(stringResource(R.string.conv_yourself), style = Type.small, color = c.muted)
            } else {
                PeerChip(peers.first()) { Links.openNostr(context, it.npub, it.profileUrl) }
                if (peers.size > 1) {
                    Text(pluralStringResource(R.plurals.conv_and_more, peers.size - 1, peers.size - 1), style = Type.small, color = c.muted)
                }
            }
        }
        if (peers.size > 1) {
            Text(stringResource(R.string.conv_all_participants).uppercase(), style = Type.slug, color = c.muted)
            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                peers.forEach { peer -> PeerChip(peer) { Links.openNostr(context, it.npub, it.profileUrl) } }
            }
        }
        conversation.subject?.takeIf { it.isNotBlank() }?.let { Text(it, style = Type.bodyDense, color = c.text) }
        if (conversation.legacy) {
            Column(Modifier.fillMaxWidth().background(c.alarmFill).padding(12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(stringResource(R.string.conv_legacy_title).uppercase(), style = Type.label, color = c.redText)
                Text(stringResource(R.string.conv_legacy_body), style = Type.small, color = c.text)
            }
        }
    }
    Rule()
}

@Composable
private fun PeerChip(person: Person, onOpen: (Person) -> Unit) {
    val c = LocalConsole.current
    Row(Modifier.clickable { onOpen(person) }, verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        Avatar(person.pictureUrl, person.name ?: "?", 24.dp)
        Text(person.name ?: person.npub?.take(16).orEmpty(), style = Type.bodyDense, color = c.text, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

@Composable
private fun RequestBar(onAccept: () -> Unit, onBlock: () -> Unit) {
    val c = LocalConsole.current
    Column(Modifier.fillMaxWidth().background(c.panel).padding(Gutter), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Text(stringResource(R.string.conv_request_body), style = Type.small, color = c.legend)
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            PrimaryButton(stringResource(R.string.conv_accept), onAccept, Modifier.weight(1f))
            SecondaryButton(stringResource(R.string.conv_block), onBlock, Modifier.weight(1f), danger = true)
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun Bubble(
    message: Message,
    showSender: Boolean,
    quoted: Message?,
    canReply: Boolean,
    risks: List<String>,
    onReply: () -> Unit,
    onRetry: () -> Unit,
    onDowngrade: () -> Unit,
) {
    val c = LocalConsole.current
    val context = LocalContext.current
    var menu by remember { mutableStateOf(false) }
    var confirmDowngrade by remember { mutableStateOf(false) }

    Box(Modifier.fillMaxWidth(), contentAlignment = if (message.outbound) Alignment.CenterEnd else Alignment.CenterStart) {
        Column(
            Modifier
                .widthIn(max = 320.dp)
                .background(if (message.outbound) c.panelHi else c.panel)
                .border(1.dp, if (message.status == "failed") c.red else c.rule)
                .combinedClickable(onClick = {}, onLongClick = { menu = true })
                .padding(horizontal = 12.dp, vertical = 9.dp),
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            if (showSender) Text(message.sender.name.orEmpty().uppercase(), style = Type.slug, color = c.amberText)
            quoted?.let {
                Text("↳ " + (it.content ?: stringResource(R.string.bub_encrypted_file)), style = Type.small, color = c.muted,
                    maxLines = 2, overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.fillMaxWidth().border(1.dp, c.rule).padding(6.dp))
            }
            if (message.file) {
                Text(stringResource(R.string.bub_encrypted_file), style = Type.bodyDense, color = c.muted)
            } else {
                RichContent(message.content, message.references, style = Type.bodyDense)
            }

            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                val sent = Times.parse(message.sentAt)
                Text(if (sent != null && Times.isToday(sent)) Times.hour(sent) else Times.dateTime(sent), style = Type.mono, color = c.muted)
                when {
                    message.legacyDowngrade -> Slug(stringResource(R.string.bub_downgrade_badge), SlugTone.Short)
                    message.legacy -> Slug(stringResource(R.string.bub_legacy_badge))
                }
                if (message.deliveryNote != null) Slug(stringResource(R.string.bub_best_effort), SlugTone.Wait)
            }
            message.deliveryNote?.let { Text(it, style = Type.small, color = c.muted) }
            if (message.sending) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    CircularProgressIndicator(Modifier.size(12.dp), color = Palette.amber, strokeWidth = 1.5.dp)
                    Text(message.step ?: stringResource(R.string.bub_sending), style = Type.small, color = c.amberText)
                }
            }
            if (message.status == "failed") {
                Text(stringResource(R.string.fail_not_sent).uppercase() + (message.error?.let { " · $it" } ?: ""),
                    style = Type.small, color = c.redText)
                if (message.canRetry) {
                    Row {
                        SlugButton(stringResource(R.string.fail_try_again), onRetry, tone = SlugTone.Short)
                        if (!message.legacy) SlugButton(stringResource(R.string.fail_legacy_summary), { confirmDowngrade = true })
                    }
                }
            }
        }
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            if (canReply) {
                DropdownMenuItem(text = { Text(stringResource(R.string.conv_reply)) }, onClick = { menu = false; onReply() })
            }
            message.content?.let { text ->
                DropdownMenuItem(text = { Text(stringResource(R.string.action_copy)) }, onClick = { menu = false; Links.copy(context, "message", text) })
            }
        }
    }

    if (confirmDowngrade) {
        ConfirmDialog(
            stringResource(R.string.fail_legacy_intro),
            stringResource(R.string.comp_send_public_metadata),
            onConfirm = onDowngrade,
            onDismiss = { confirmDowngrade = false },
        ) {
            RiskList(risks)
            Text(stringResource(R.string.fail_moves_to_legacy), style = Type.small, color = c.muted)
        }
    }
}

/**
 * The reply box, shaped by how a reply can be delivered (Messaging::DeliveryMode):
 * strong encryption normally, an honest best-effort note when the peer has no
 * DM inbox (with the acknowledged legacy downgrade one step away), the public-
 * metadata warning in a legacy thread, and no box at all when the signer has
 * not granted messaging.
 */
@Composable
private fun Composer(
    thread: Thread,
    draft: String,
    onDraft: (String) -> Unit,
    replyTo: Message?,
    onClearReply: () -> Unit,
    sending: Boolean,
    onSend: (legacyAck: Boolean) -> Unit,
    onEnableMessaging: () -> Unit,
) {
    val c = LocalConsole.current
    val delivery = thread.delivery
    var asLegacy by rememberSaveable { mutableStateOf(false) }

    Column(Modifier.fillMaxWidth().background(c.chassis).padding(Gutter), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        if (delivery == "unavailable") {
            NoteBlock(stringResource(R.string.comp_unavailable))
            PrimaryButton(stringResource(R.string.msg_enable_messaging), onEnableMessaging, Modifier.fillMaxWidth())
            return@Column
        }

        val legacyThread = delivery == "legacy"
        val legacySend = legacyThread || (delivery == "best_effort" && asLegacy)
        when (delivery) {
            "checking" -> Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                CircularProgressIndicator(Modifier.size(14.dp), color = Palette.amber, strokeWidth = 1.5.dp)
                Text(stringResource(R.string.comp_checking), style = Type.small, color = c.muted)
            }
            "best_effort" -> {
                WaitBlock(stringResource(R.string.comp_no_inbox_title) + "\n" + stringResource(R.string.comp_no_inbox_body))
                Text(stringResource(R.string.comp_strong_best_effort).uppercase(), style = Type.slug, color = c.amberText)
            }
            "legacy" -> Text(stringResource(R.string.comp_basic_encryption).uppercase(), style = Type.slug, color = c.redText)
            "self" -> Text(stringResource(R.string.conv_note_to_self).uppercase(), style = Type.slug, color = c.muted)
            else -> Text(stringResource(R.string.comp_strong_private).uppercase(), style = Type.slug, color = c.muted)
        }

        if (delivery == "best_effort") {
            Row(Modifier.clickable { asLegacy = !asLegacy }, verticalAlignment = Alignment.CenterVertically) {
                Checkbox(asLegacy, { asLegacy = it }, colors = CheckboxDefaults.colors(checkedColor = c.red))
                Text(stringResource(R.string.comp_legacy_summary), style = Type.small, color = c.text)
            }
            if (asLegacy) {
                Column(Modifier.fillMaxWidth().background(c.alarmFill).padding(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text(stringResource(R.string.comp_legacy_intro), style = Type.small, color = c.text)
                    RiskList(thread.legacyDowngradeRisks)
                    Text(stringResource(R.string.comp_legacy_separate), style = Type.small, color = c.muted)
                }
            }
        }

        replyTo?.let { target ->
            Row(Modifier.fillMaxWidth().border(1.dp, c.rule).padding(start = 10.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(stringResource(R.string.conv_replying_to, target.content ?: stringResource(R.string.bub_encrypted_file)),
                    style = Type.small, color = c.legend, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
                IconButton(onClick = onClearReply) { Icon(Icons.Filled.Close, contentDescription = stringResource(R.string.action_cancel), tint = c.muted) }
            }
        }

        OutlinedTextField(
            draft, onDraft,
            placeholder = {
                Text(stringResource(when {
                    legacyThread -> R.string.comp_legacy_reply_placeholder
                    legacySend -> R.string.comp_legacy_placeholder
                    else -> R.string.comp_placeholder
                }))
            },
            maxLines = 6,
            modifier = Modifier.fillMaxWidth(),
            colors = OutlinedTextFieldDefaults.colors(focusedBorderColor = Palette.amber, unfocusedBorderColor = c.rule, cursorColor = Palette.amber),
        )
        if (legacySend) {
            SecondaryButton(stringResource(R.string.comp_send_public_metadata), { onSend(true) }, Modifier.fillMaxWidth(),
                enabled = draft.isNotBlank() && !sending, danger = true)
        } else {
            PrimaryButton(stringResource(R.string.comp_send), { onSend(false) }, Modifier.fillMaxWidth(),
                enabled = draft.isNotBlank(), busy = sending)
        }
    }
}
