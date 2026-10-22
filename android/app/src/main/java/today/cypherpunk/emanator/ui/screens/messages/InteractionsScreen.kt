package today.cypherpunk.emanator.ui.screens.messages

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CheckboxDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.LocalTextStyle
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
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
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.boundsInWindow
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.LifecycleEventEffect
import androidx.lifecycle.viewModelScope
import androidx.navigation.NavHostController
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import today.cypherpunk.emanator.AppContainer
import today.cypherpunk.emanator.R
import today.cypherpunk.emanator.data.AccountMini
import today.cypherpunk.emanator.data.AccountsResponse
import today.cypherpunk.emanator.data.ApiException
import today.cypherpunk.emanator.data.Interaction
import today.cypherpunk.emanator.data.InteractionsResponse
import today.cypherpunk.emanator.data.Loadable
import today.cypherpunk.emanator.data.Mention
import today.cypherpunk.emanator.data.cachedFlow
import today.cypherpunk.emanator.ui.Routes
import today.cypherpunk.emanator.ui.appViewModel
import today.cypherpunk.emanator.ui.components.Avatar
import today.cypherpunk.emanator.ui.components.ConsoleScaffold
import today.cypherpunk.emanator.ui.components.EmptyState
import today.cypherpunk.emanator.ui.components.ErrorState
import today.cypherpunk.emanator.ui.components.Gutter
import today.cypherpunk.emanator.ui.components.MentionLookup
import today.cypherpunk.emanator.ui.components.MentionPopup
import today.cypherpunk.emanator.ui.components.PrimaryButton
import today.cypherpunk.emanator.ui.components.RichContent
import today.cypherpunk.emanator.ui.components.Rule
import today.cypherpunk.emanator.ui.components.SavedCopyNotice
import today.cypherpunk.emanator.ui.components.Slug
import today.cypherpunk.emanator.ui.components.SlugButton
import today.cypherpunk.emanator.ui.components.SlugTone
import today.cypherpunk.emanator.ui.components.WaitBlock
import today.cypherpunk.emanator.ui.theme.LocalConsole
import today.cypherpunk.emanator.ui.theme.Palette
import today.cypherpunk.emanator.ui.theme.Type
import today.cypherpunk.emanator.util.Links
import today.cypherpunk.emanator.util.Times

/** Progress of one background action (like / follow / mute / reply), as words. */
enum class ActionPhase { Processing, Approve, Publishing, Done, Failed, Stalled }

data class CardState(
    val like: ActionPhase? = null,
    val follow: ActionPhase? = null,
    val mute: ActionPhase? = null,
    val reply: ActionPhase? = null,
    val replyCreating: Boolean = false,
    val replyPostId: Long? = null,
    val error: String? = null,
)

/**
 * Replies, quotes and mentions across every identity (web: interactions#index).
 * Read from the server's interactions cache; while it says a refresh is under
 * way, ask again every few seconds. Like / follow / mute / reply are signed by
 * the account's signer in the background and polled until they land.
 */
class InteractionsViewModel(private val container: AppContainer) : ViewModel() {
    private val _state = MutableStateFlow(Loadable<InteractionsResponse>())
    val state = _state.asStateFlow()
    private val _accounts = MutableStateFlow<List<AccountMini>>(emptyList())
    val accounts = _accounts.asStateFlow()
    private val _cards = MutableStateFlow<Map<String, CardState>>(emptyMap())
    val cards = _cards.asStateFlow()
    /** Authors muted in this session, hidden at once rather than after the next refresh. */
    private val _muted = MutableStateFlow<Set<String>>(emptySet())
    val muted = _muted.asStateFlow()

    init {
        viewModelScope.launch {
            cachedFlow(container.cache, "accounts", AccountsResponse.serializer()) { container.api.accounts() }
                .collect { s -> s.data?.let { _accounts.value = it.accounts.map { a -> a.mini() } } }
        }
        refresh()
    }

    fun refresh() {
        viewModelScope.launch {
            cachedFlow(container.cache, "interactions", InteractionsResponse.serializer()) { container.api.interactions() }
                .collect { _state.value = it }
        }
    }

    /** Re-ask quietly, keeping what is shown. */
    fun poll() {
        viewModelScope.launch {
            try {
                val fresh = container.api.interactions()
                container.cache.write("interactions", InteractionsResponse.serializer(), fresh)
                _state.value = Loadable(fresh)
            } catch (_: ApiException) {
            }
        }
    }

    private fun card(eventId: String, change: (CardState) -> CardState) =
        _cards.update { it + (eventId to change(it[eventId] ?: CardState())) }

    fun like(item: Interaction) = action(item, "reaction") { s, p -> s.copy(like = p) }
    fun follow(item: Interaction) = action(item, "follow") { s, p -> s.copy(follow = p) }
    fun mute(item: Interaction) {
        item.author.pubkeyHex?.let { pk -> _muted.update { it + pk } }
        action(item, "mute") { s, p -> s.copy(mute = p) }
    }

    private fun action(item: Interaction, type: String, set: (CardState, ActionPhase) -> CardState) {
        val account = item.account ?: return
        val author = item.author.pubkeyHex ?: return
        card(item.eventId) { set(it, ActionPhase.Processing).copy(error = null) }
        viewModelScope.launch {
            try {
                var result = container.api.nostrAction(account.id, type, if (type == "follow" || type == "mute") null else item.eventId, author)
                val deadline = System.currentTimeMillis() + 3 * 60_000
                while (result.status != "published" && result.status != "failed" && System.currentTimeMillis() < deadline) {
                    card(item.eventId) { set(it, phaseOf(result.status)) }
                    delay(2_000)
                    result = container.api.nostrActionStatus(result.id)
                }
                card(item.eventId) {
                    set(it, when (result.status) {
                        "published" -> ActionPhase.Done
                        "failed" -> ActionPhase.Failed
                        else -> ActionPhase.Stalled
                    }).copy(error = result.error)
                }
            } catch (e: ApiException) {
                card(item.eventId) { set(it, ActionPhase.Failed).copy(error = e.message) }
            }
        }
    }

    private fun phaseOf(status: String) = when (status) {
        "awaiting_signature" -> ActionPhase.Approve
        "publishing" -> ActionPhase.Publishing
        else -> ActionPhase.Processing
    }

    /** Mentions::Search for the reply box too — the same lookup as the composer. */
    suspend fun searchMentions(query: String): List<Mention> =
        runCatching { container.api.mentions(query).mentions }.getOrDefault(emptyList())

    /** Replies sign at once (no scheduling) — the same path as the web's inline reply. */
    fun reply(item: Interaction, text: String, alsoLike: Boolean, alsoFollow: Boolean) {
        val account = item.account ?: return
        card(item.eventId) { it.copy(replyCreating = true, reply = null, error = null) }
        viewModelScope.launch {
            try {
                val created = container.api.createReply(account.id, text.trim(), item.eventId, item.author.pubkeyHex, item.rootEventId)
                card(item.eventId) { it.copy(replyCreating = false, replyPostId = created.post.id, reply = ActionPhase.Approve) }
                if (alsoLike && !item.alreadyLiked) like(item)
                if (alsoFollow && !item.alreadyFollowing) follow(item)
                var status = created.post.status
                val deadline = System.currentTimeMillis() + 3 * 60_000
                while (status != "published" && status != "failed" && System.currentTimeMillis() < deadline) {
                    delay(2_000)
                    status = container.api.post(created.post.id).post.status
                    card(item.eventId) {
                        it.copy(reply = if (status == "awaiting_signature") ActionPhase.Approve else ActionPhase.Publishing)
                    }
                }
                card(item.eventId) {
                    it.copy(reply = when (status) {
                        "published" -> ActionPhase.Done
                        "failed" -> ActionPhase.Failed
                        else -> ActionPhase.Stalled
                    })
                }
            } catch (e: ApiException) {
                card(item.eventId) { it.copy(replyCreating = false, reply = ActionPhase.Failed, error = e.message) }
            }
        }
    }
}

private val Types = listOf("reply", "quote", "mention")

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun InteractionsScreen(nav: NavHostController) {
    val vm = appViewModel { InteractionsViewModel(it) }
    val state by vm.state.collectAsState()
    val accounts by vm.accounts.collectAsState()
    val cards by vm.cards.collectAsState()
    val muted by vm.muted.collectAsState()
    val c = LocalConsole.current
    // null = every account; filters are client-side, like the web's.
    var selected by rememberSaveable { mutableStateOf<Set<Long>?>(null) }
    var type by rememberSaveable { mutableStateOf<String?>(null) }

    LifecycleEventEffect(Lifecycle.Event.ON_RESUME) { vm.poll() }
    val refreshing = state.data?.refreshing == true
    LaunchedEffect(refreshing) {
        while (refreshing) {
            delay(5_000)
            vm.poll()
        }
    }

    ConsoleScaffold(stringResource(R.string.nav_interactions), onBack = { nav.popBackStack() }) { padding ->
        PullToRefreshBox(
            isRefreshing = state.loading && state.data != null,
            onRefresh = vm::refresh,
            modifier = Modifier.fillMaxSize().padding(padding),
        ) {
            val data = state.data
            LazyColumn(Modifier.fillMaxSize()) {
                item {
                    if (state.loading || refreshing) {
                        LinearProgressIndicator(Modifier.fillMaxWidth().height(2.dp), color = Palette.amber, trackColor = Color.Transparent)
                    }
                    if (accounts.isNotEmpty()) {
                        Text(pluralStringResource(R.plurals.int_subtitle, accounts.size, accounts.size).uppercase(), style = Type.slug, color = c.muted,
                            modifier = Modifier.padding(horizontal = Gutter, vertical = 10.dp))
                    }
                }
                if (data == null) {
                    item {
                        if (state.error != null) ErrorState(state.error!!, vm::refresh)
                        else Box(Modifier.fillMaxWidth().padding(48.dp), contentAlignment = Alignment.Center) {
                            CircularProgressIndicator(color = Palette.amber, strokeWidth = 2.dp)
                        }
                    }
                    return@LazyColumn
                }
                state.error?.let { if (!it.isUnauthorized) item { SavedCopyNotice(it) } }
                if (refreshing) item { WaitBlock(stringResource(R.string.int_loading), Modifier.padding(horizontal = Gutter, vertical = 6.dp)) }

                item {
                    if (accounts.size > 1) {
                        AccountPills(
                            accounts,
                            selected ?: emptySet(),
                            { id ->
                                val current = selected ?: accounts.map { it.id }.toSet()
                                selected = if (id in current) current - id else current + id
                            },
                            Modifier.padding(horizontal = Gutter, vertical = 6.dp),
                            allWhenEmpty = selected == null,
                        )
                        SlugButton(
                            stringResource(if (selected?.isEmpty() == true) R.string.msg_select_all else R.string.int_unselect_all),
                            { selected = if (selected?.isEmpty() == true) null else emptySet() },
                            Modifier.padding(start = Gutter - 8.dp),
                        )
                    }
                    Row(Modifier.horizontalScroll(rememberScrollState()).padding(horizontal = Gutter, vertical = 6.dp),
                        horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        TypeChip(stringResource(R.string.int_all), type == null) { type = null }
                        Types.forEach { t -> TypeChip(typeLabel(t), type == t) { type = if (type == t) null else t } }
                    }
                    Rule()
                }

                val visible = data.interactions.filter { item ->
                    (selected == null || item.account?.id in selected!!) &&
                        (type == null || item.type == type) &&
                        item.author.pubkeyHex !in muted
                }
                when {
                    selected?.isEmpty() == true -> item {
                        Column(Modifier.padding(Gutter)) {
                            Text(stringResource(R.string.int_none_selected_title).uppercase(), style = Type.label, color = c.text)
                            Text(stringResource(R.string.int_none_selected_body), style = Type.small, color = c.muted)
                        }
                    }
                    data.interactions.isEmpty() && !refreshing -> item {
                        Column(Modifier.padding(Gutter)) {
                            Text(stringResource(R.string.int_empty_title).uppercase(), style = Type.label, color = c.text)
                            Text(stringResource(R.string.int_empty_body), style = Type.small, color = c.muted)
                        }
                    }
                    visible.isEmpty() -> item { EmptyState(stringResource(R.string.state_nothing_here)) }
                    else -> items(visible, key = { it.eventId }) { item ->
                        InteractionCard(
                            item = item,
                            card = cards[item.eventId] ?: CardState(),
                            onLike = { vm.like(item) },
                            onFollow = { vm.follow(item) },
                            onMute = { vm.mute(item) },
                            onReply = { text, like, follow -> vm.reply(item, text, like, follow) },
                            onOpenPost = { id -> nav.navigate(Routes.post(id)) },
                            onSearchMentions = vm::searchMentions,
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun typeLabel(type: String) = when (type) {
    "reply" -> stringResource(R.string.int_type_reply)
    "quote" -> stringResource(R.string.int_type_quote)
    "mention" -> stringResource(R.string.int_type_mention)
    else -> type
}

@Composable
private fun TypeChip(label: String, active: Boolean, onClick: () -> Unit) {
    val c = LocalConsole.current
    Text(
        label.uppercase(), style = Type.label, color = if (active) c.text else c.muted,
        modifier = Modifier.border(1.dp, if (active) c.text else c.rule).clickable(onClick = onClick)
            .padding(horizontal = 10.dp, vertical = 7.dp),
    )
}

@Composable
private fun phaseText(phase: ActionPhase, done: Int) = stringResource(
    when (phase) {
        ActionPhase.Processing -> R.string.act_processing
        ActionPhase.Approve -> R.string.act_approve
        ActionPhase.Publishing -> R.string.act_publishing
        ActionPhase.Done -> done
        ActionPhase.Failed -> R.string.act_failed
        ActionPhase.Stalled -> R.string.reply_signing_stalled
    },
)

@Composable
private fun InteractionCard(
    item: Interaction,
    card: CardState,
    onLike: () -> Unit,
    onFollow: () -> Unit,
    onMute: () -> Unit,
    onReply: (String, Boolean, Boolean) -> Unit,
    onOpenPost: (Long) -> Unit,
    onSearchMentions: suspend (String) -> List<Mention>,
) {
    val c = LocalConsole.current
    val context = LocalContext.current
    var replying by rememberSaveable(item.eventId) { mutableStateOf(false) }
    // TextFieldValue, not String: the mention lookup needs the caret.
    var replyText by rememberSaveable(item.eventId, stateSaver = TextFieldValue.Saver) { mutableStateOf(TextFieldValue("")) }
    val replyScope = rememberCoroutineScope()
    val mentionLookup = remember(item.eventId) { MentionLookup(replyScope, onSearchMentions) }
    val mentioned by mentionLookup.suggestions.collectAsState()
    var fieldBounds by remember { mutableStateOf<Rect?>(null) }
    var alsoLike by rememberSaveable(item.eventId) { mutableStateOf(false) }
    var alsoFollow by rememberSaveable(item.eventId) { mutableStateOf(false) }
    var confirmMute by remember { mutableStateOf(false) }
    var expanded by remember { mutableStateOf(false) }
    val authorName = item.author.name ?: item.author.npub?.take(16) ?: item.author.pubkeyHex?.take(12).orEmpty()

    Column(Modifier.fillMaxWidth().padding(horizontal = Gutter, vertical = 14.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        item.original?.let { original ->
            val label = stringResource(when {
                original.owned -> R.string.int_your_post
                item.type == "quote" -> R.string.int_quoted_post
                else -> R.string.int_in_reply_to
            })
            val author = original.authorName ?: original.authorPubkey?.take(8)
            Column(
                Modifier.fillMaxWidth().border(1.dp, c.rule).clickable {
                    original.postId?.let(onOpenPost) ?: Links.openNostr(context, null, original.viewerUrl)
                }.padding(10.dp),
            ) {
                Text(
                    (if (!original.owned && author != null) stringResource(R.string.int_labelled, label, author) else label).uppercase(),
                    style = Type.slug, color = c.muted,
                )
                Text(original.content, style = Type.small, color = c.legend, maxLines = if (expanded) Int.MAX_VALUE else 3,
                    overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(top = 4.dp))
                if (!expanded && original.content.length > 180) {
                    SlugButton(stringResource(R.string.int_show_more), { expanded = true })
                }
            }
        }

        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Box(Modifier.clickable { Links.openNostr(context, item.author.npub, item.author.profileUrl) }) {
                Avatar(item.author.pictureUrl, authorName, 40.dp)
            }
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(authorName, style = Type.bodyDense, color = c.text, maxLines = 1, overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f, fill = false).clickable { Links.openNostr(context, item.author.npub, item.author.profileUrl) })
                    Slug(typeLabel(item.type))
                    Text(Times.age(Times.parse(item.createdAt)), style = Type.mono, color = c.muted)
                }
                item.account?.let {
                    Text(stringResource(R.string.int_to_account, it.username ?: it.name), style = Type.small, color = c.muted)
                }
                RichContent(item.content, item.references, style = Type.bodyDense)
            }
        }

        if (item.account?.hasSigner == true) {
            Row(Modifier.horizontalScroll(rememberScrollState()), verticalAlignment = Alignment.CenterVertically) {
                val liked = item.alreadyLiked || card.like == ActionPhase.Done
                when {
                    card.like != null && card.like != ActionPhase.Done ->
                        Slug(phaseText(card.like, R.string.act_liked), if (card.like == ActionPhase.Failed) SlugTone.Short else SlugTone.Wait)
                    liked -> Slug(stringResource(R.string.act_liked))
                    else -> SlugButton(stringResource(R.string.int_like), onLike)
                }
                val following = item.alreadyFollowing || card.follow == ActionPhase.Done
                when {
                    card.follow != null && card.follow != ActionPhase.Done ->
                        Slug(phaseText(card.follow, R.string.act_followed), if (card.follow == ActionPhase.Failed) SlugTone.Short else SlugTone.Wait)
                    following -> Slug(stringResource(R.string.act_following))
                    else -> SlugButton(stringResource(R.string.int_follow), onFollow)
                }
                SlugButton(stringResource(R.string.int_reply), { replying = !replying }, tone = if (replying) SlugTone.Wait else SlugTone.Plain)
                SlugButton(stringResource(R.string.int_mute, authorName), { confirmMute = true })
                SlugButton(stringResource(R.string.action_open_in_client), { Links.openNostr(context, item.nevent, item.viewerUrl) })
            }
        } else {
            SlugButton(stringResource(R.string.action_open_in_client), { Links.openNostr(context, item.nevent, item.viewerUrl) })
        }
        card.error?.let { Text(it, style = Type.small, color = c.redText) }

        if (replying) {
            Column(Modifier.fillMaxWidth().background(c.panel).padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(stringResource(R.string.int_replying_as, item.account?.name.orEmpty()).uppercase(), style = Type.slug, color = c.muted)
                Box {
                    OutlinedTextField(
                        replyText,
                        {
                            replyText = it
                            mentionLookup.onTextChange(it)
                        },
                        placeholder = { Text(stringResource(R.string.int_reply_placeholder)) },
                        minLines = 3, maxLines = 8,
                        modifier = Modifier.fillMaxWidth().onGloballyPositioned { fieldBounds = it.boundsInWindow() },
                        enabled = card.reply == null || card.reply == ActionPhase.Failed,
                        colors = OutlinedTextFieldDefaults.colors(focusedBorderColor = Palette.amber, unfocusedBorderColor = c.rule, cursorColor = Palette.amber),
                    )
                    // The same @mention list the composer has: replying is where
                    // you most often want to name someone.
                    MentionPopup(
                        mentions = mentioned,
                        text = replyText,
                        bounds = fieldBounds,
                        textStyle = LocalTextStyle.current,
                        onPick = { mention -> mentionLookup.pick(replyText, mention)?.let { replyText = it } },
                        onDismiss = mentionLookup::dismiss,
                    )
                }
                if (!item.alreadyLiked) CheckRow(stringResource(R.string.int_like_this_post), alsoLike) { alsoLike = it }
                if (!item.alreadyFollowing) CheckRow(stringResource(R.string.int_follow_author, authorName), alsoFollow) { alsoFollow = it }
                when {
                    card.replyCreating -> Progress(stringResource(R.string.reply_creating))
                    card.reply == ActionPhase.Approve -> Progress(stringResource(R.string.reply_signing_approve))
                    card.reply == ActionPhase.Publishing -> Progress(stringResource(R.string.act_publishing))
                    card.reply == ActionPhase.Done -> Text(stringResource(R.string.reply_published), style = Type.small, color = c.text)
                    card.reply == ActionPhase.Stalled -> Column {
                        Text(stringResource(R.string.reply_signing_stalled), style = Type.small, color = c.redText)
                        card.replyPostId?.let { id -> SlugButton(stringResource(R.string.row_open), { onOpenPost(id) }, tone = SlugTone.Short) }
                    }
                    card.reply == ActionPhase.Failed && card.replyPostId != null -> Column {
                        Text(stringResource(R.string.reply_publishing_failed), style = Type.small, color = c.redText)
                        SlugButton(stringResource(R.string.row_open), { onOpenPost(card.replyPostId) }, tone = SlugTone.Short)
                    }
                }
                if (card.reply == null || (card.reply == ActionPhase.Failed && card.replyPostId == null)) {
                    Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
                        PrimaryButton(stringResource(R.string.int_sign_and_publish), { onReply(replyText.text, alsoLike, alsoFollow) },
                            enabled = replyText.text.isNotBlank(), busy = card.replyCreating)
                        SlugButton(stringResource(R.string.action_cancel), { replying = false })
                    }
                }
            }
        }
    }
    Rule()

    if (confirmMute) {
        ConfirmDialog(
            stringResource(R.string.int_mute_confirm, "@$authorName"),
            stringResource(R.string.int_mute, authorName),
            onConfirm = onMute,
            onDismiss = { confirmMute = false },
        )
    }
}

@Composable
private fun CheckRow(label: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    Row(Modifier.clickable { onChange(!checked) }, verticalAlignment = Alignment.CenterVertically) {
        Checkbox(checked, onChange, colors = CheckboxDefaults.colors(checkedColor = Palette.amber, checkmarkColor = Palette.contactBlack))
        Text(label, style = Type.small, color = LocalConsole.current.text)
    }
}

@Composable
private fun Progress(text: String) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        CircularProgressIndicator(Modifier.size(14.dp), color = Palette.amber, strokeWidth = 1.5.dp)
        Text(text, style = Type.small, color = LocalConsole.current.amberText)
    }
}
