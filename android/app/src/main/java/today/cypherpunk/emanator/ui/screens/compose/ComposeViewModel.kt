package today.cypherpunk.emanator.ui.screens.compose

import android.content.Context
import android.net.Uri
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.contentOrNull
import today.cypherpunk.emanator.AppContainer
import today.cypherpunk.emanator.data.Account
import today.cypherpunk.emanator.data.ApiException
import today.cypherpunk.emanator.data.AppJson
import today.cypherpunk.emanator.data.Billing
import today.cypherpunk.emanator.data.MediaSettings
import today.cypherpunk.emanator.data.Mention
import today.cypherpunk.emanator.data.SseEvent
import today.cypherpunk.emanator.media.ImageShrinker
import today.cypherpunk.emanator.media.TextInsert
import today.cypherpunk.emanator.media.VideoRules
import today.cypherpunk.emanator.ui.components.MentionLookup

/** One file on its way into the post. The UI words it; see [UploadPhase]. */
data class UploadLine(val key: Int, val name: String, val phase: UploadPhase, val note: UploadNote? = null)

/** What shrinking did, shown under the file's progress bar. */
sealed interface UploadNote {
    data class Shrunk(val from: Long, val to: Long) : UploadNote
    /** "Smaller of the two" kept the original: re-encoding came out at [reencoded]. */
    data class KeptOriginal(val original: Long, val reencoded: Long) : UploadNote
}

sealed interface UploadPhase {
    /** Copying the file in, and shrinking it if it is a photo. */
    data object Preparing : UploadPhase
    /** A video being re-encoded on the phone. */
    data class Encoding(val percent: Int) : UploadPhase
    /** Sending the file to Emanator. */
    data class Sending(val percent: Int) : UploadPhase
    /** Emanator passes it on to the media server. */
    data object Uploading : UploadPhase
    /** The server's own progress line ("Approve the upload in your signer app…"). */
    data class Step(val text: String) : UploadPhase
    data object Done : UploadPhase
    data class TooLarge(val size: Long, val limit: Long) : UploadPhase
    data object TimedOut : UploadPhase
    data class Failed(val message: String?) : UploadPhase

    val inFlight get() = this is Preparing || this is Encoding || this is Sending || this is Uploading || this is Step
}

/** Where an AI request stands. `phase` is "connecting", "generating", "humanizing" or "refining". */
data class AiState(
    val running: Boolean = false,
    val phase: String? = null,
    val refining: Boolean = false,
    val preview: String = "",
    val completed: Boolean = false,
    val error: String? = null,
    val paywall: Boolean = false,
    /** The text the AI result replaced, for Undo. */
    val replaced: String? = null,
)

/** Videos that could go up unconverted, waiting for the user to say how. */
data class VideoChoice(val names: List<String>, val uris: List<Uri>, val askable: Set<Uri>, val accountId: Long)

data class ComposeUi(
    val loading: Boolean = true,
    val accounts: List<Account> = emptyList(),
    val accountId: Long? = null,
    val editing: Boolean = false,
    val canEdit: Boolean = true,
    val restoredDraft: Boolean = false,
    val uploads: List<UploadLine> = emptyList(),
    val videoChoice: VideoChoice? = null,
    val saving: Boolean = false,
    val error: String? = null,
    val ai: AiState = AiState(),
    val billing: Billing? = null,
) {
    val account get() = accounts.firstOrNull { it.id == accountId }
    val uploading get() = uploads.any { it.phase.inFlight }
}

sealed interface ComposeEvent {
    data class Schedule(val postId: Long) : ComposeEvent
    data class Open(val postId: Long) : ComposeEvent
}

/**
 * The post composer: picks the identity, keeps an unsaved draft on the phone,
 * uploads attachments (shrunk first) into the text at the caret, and streams
 * AI drafts. Saving goes straight to scheduling, as on the web.
 */
class ComposeViewModel(
    private val container: AppContainer,
    private val requestedAccountId: Long?,
    private val postId: Long?,
    fromShare: Boolean,
) : ViewModel() {
    val ui = MutableStateFlow(ComposeUi(editing = postId != null))
    val text = MutableStateFlow(TextFieldValue(""))
    /** @mention suggestions for the word being typed (Mentions::Search on the server). */
    private val mentionLookup = MentionLookup(viewModelScope) { query -> container.api.mentions(query).mentions }
    val mentions = mentionLookup.suggestions
    private val events = Channel<ComposeEvent>(Channel.BUFFERED)
    val navigation = events.receiveAsFlow()

    private val drafts = container.context.getSharedPreferences("compose_drafts", Context.MODE_PRIVATE)
    // A share gets its own slot, so sharing a link never overwrites the post
    // the user was halfway through.
    private val draftKey = postId?.let { "post:$it" } ?: if (fromShare) "shared" else "new"
    private val shrinker = ImageShrinker(container.context)
    private var nextKey = 0
    private var insertionPoint: Int? = null
    private var uploadLimit: Long? = null
    private var aiJob: Job? = null
    private val pendingUris = mutableListOf<Uri>()

    init {
        if (!fromShare && postId == null) {
            drafts.getString(draftKey, null)?.takeIf { it.isNotBlank() }?.let {
                setText(it, save = false)
                ui.update { s -> s.copy(restoredDraft = true) }
            }
        }
        viewModelScope.launch { load() }
        // Shares are taken from the container as they arrive — including a
        // second one while this composer is already open, which navigation
        // (launchSingleTop) brings back here rather than to a new screen.
        if (fromShare) viewModelScope.launch {
            container.shared.collect { shared ->
                if (shared == null) return@collect
                container.shared.value = null
                shared.text?.takeIf { it.isNotBlank() }?.let { incoming ->
                    val current = text.value.text
                    setText(if (current.isBlank()) incoming else current.trimEnd() + "\n\n" + incoming)
                }
                attach(shared.uris)
            }
        }
    }

    private suspend fun load() {
        try {
            val accounts = container.api.accounts().accounts
            var accountId = requestedAccountId
            if (postId != null) {
                val post = container.api.post(postId).post
                accountId = post.accountId
                val local = drafts.getString(draftKey, null)
                if (!local.isNullOrBlank() && local != post.content) {
                    setText(local, save = false)
                    ui.update { it.copy(restoredDraft = true) }
                } else {
                    setText(post.content.orEmpty(), save = false)
                }
                ui.update { it.copy(canEdit = post.can.edit) }
            }
            if (accountId == null || accounts.none { it.id == accountId }) {
                val stored = drafts.getLong("$draftKey.account", 0L).takeIf { it > 0 } ?: container.prefs.lastAccountId
                accountId = accounts.firstOrNull { it.id == stored }?.id ?: accounts.firstOrNull()?.id
            }
            ui.update { it.copy(loading = false, accounts = accounts, accountId = accountId) }
            if (pendingUris.isNotEmpty() && accountId != null) {
                val uris = pendingUris.toList()
                pendingUris.clear()
                attach(uris)
            }
        } catch (e: ApiException) {
            ui.update { it.copy(loading = false, error = e.message) }
        }
        loadBilling()
    }

    private suspend fun loadBilling() {
        val me = container.me.value ?: runCatching { container.api.me().also(container::setMe) }.getOrNull()
        if (me?.billingEnabled != true) return
        runCatching { container.api.billing() }.getOrNull()?.let { billing -> ui.update { it.copy(billing = billing) } }
    }

    fun selectAccount(id: Long) {
        if (ui.value.editing) return
        ui.update { it.copy(accountId = id) }
        drafts.edit().putLong("$draftKey.account", id).apply()
    }

    fun onTextChange(value: TextFieldValue) {
        val changed = value.text != text.value.text
        text.value = value
        if (changed) saveDraft(value.text)
        mentionLookup.onTextChange(value)
    }

    /** Inserts `nostr:npub…` in place of the "@word"; the server tags it as a mention. */
    fun pickMention(mention: Mention) {
        val updated = mentionLookup.pick(text.value, mention) ?: return
        text.value = updated
        saveDraft(updated.text)
    }

    fun dismissMentions() = mentionLookup.dismiss()

    private fun setText(value: String, save: Boolean = true) {
        // A programmatic replacement (AI result, restored draft, undo) invalidates
        // the "@word" token the suggestion list was built for.
        mentionLookup.dismiss()
        text.value = TextFieldValue(value, TextRange(value.length))
        if (save) saveDraft(value)
    }

    private fun saveDraft(value: String) {
        drafts.edit().putString(draftKey, value).apply()
    }

    private fun clearDraft() {
        drafts.edit().remove(draftKey).remove("$draftKey.account").apply()
    }

    fun dismissRestored() = ui.update { it.copy(restoredDraft = false) }

    // --- attachments ---------------------------------------------------------------

    /** Each file shrinks and uploads on its own; one failing never stops the others. */
    fun attach(uris: List<Uri>) {
        val accountId = ui.value.accountId
        if (accountId == null) {
            pendingUris += uris
            return
        }
        if (uris.isEmpty()) return
        // Every URL from this batch goes where the caret was when it started.
        if (!ui.value.uploading) insertionPoint = text.value.selection.start
        viewModelScope.launch {
            // A video that could go up as it is asks how (once for the whole batch).
            val settings = mediaSettings()
            val limit = limit()
            val askable = uris.filter { uri ->
                val (mime, size) = runCatching { shrinker.describe(uri) }.getOrNull() ?: return@filter false
                size != null && VideoRules.offerChoice(mime, size, settings, limit)
            }.toSet()
            if (askable.isEmpty()) start(uris, accountId) { VideoRules.Mode.Reencode }
            else ui.update { it.copy(videoChoice = VideoChoice(askable.map(::nameOf), uris, askable, accountId)) }
        }
    }

    /** The answer to [VideoChoice]; null drops those videos, the rest still upload. */
    fun chooseVideoMode(mode: VideoRules.Mode?) {
        val choice = ui.value.videoChoice ?: return
        ui.update { it.copy(videoChoice = null) }
        val uris = if (mode == null) choice.uris.filterNot { it in choice.askable } else choice.uris
        start(uris, choice.accountId) { uri -> if (uri in choice.askable && mode != null) mode else VideoRules.Mode.Reencode }
    }

    private fun start(uris: List<Uri>, accountId: Long, modeOf: (Uri) -> VideoRules.Mode) {
        uris.forEach { uri ->
            val key = nextKey++
            track(UploadLine(key, nameOf(uri), UploadPhase.Preparing))
            viewModelScope.launch { uploadOne(key, uri, accountId, modeOf(uri)) }
        }
    }

    private fun nameOf(uri: Uri) = shrinker.displayName(uri) ?: uri.lastPathSegment ?: "…"

    private suspend fun uploadOne(key: Int, uri: Uri, accountId: Long, videoMode: VideoRules.Mode) {
        val settings = mediaSettings()
        val prepared = try {
            shrinker.prepare(uri, settings, videoMode) { percent -> setPhase(key, UploadPhase.Encoding(percent)) }
        } catch (e: Exception) {
            setPhase(key, UploadPhase.Failed(e.message))
            return
        }
        rename(key, prepared.name)
        when {
            prepared.reencodedBytes != null -> setNote(key, UploadNote.KeptOriginal(prepared.bytes, prepared.reencodedBytes))
            prepared.shrunk -> setNote(key, UploadNote.Shrunk(prepared.originalBytes, prepared.bytes))
        }
        try {
            val limit = limit()
            if (prepared.bytes > limit) {
                setPhase(key, UploadPhase.TooLarge(prepared.bytes, limit))
                return
            }
            setPhase(key, UploadPhase.Sending(0))
            val started = container.api.upload(accountId, prepared.file, prepared.name, prepared.mime) { percent ->
                setPhase(key, UploadPhase.Sending(percent.coerceAtMost(99)))
            }
            setPhase(key, UploadPhase.Uploading)
            val url = poll(key, started.id) ?: return
            insertUrl(url)
            setPhase(key, UploadPhase.Done)
            delay(DONE_VISIBLE_MS)
            dismissUpload(key)
        } catch (e: ApiException) {
            setPhase(key, UploadPhase.Failed(e.message))
        } finally {
            prepared.file.delete()
        }
    }

    /** Polls the upload once a second, showing the server's step; null on failure. */
    private suspend fun poll(key: Int, id: Long): String? {
        val deadline = System.currentTimeMillis() + POLL_TIMEOUT_MS
        while (System.currentTimeMillis() < deadline) {
            delay(1000)
            val status = try {
                container.api.uploadStatus(id)
            } catch (e: ApiException) {
                if (e.isNetwork) continue
                setPhase(key, UploadPhase.Failed(e.message))
                return null
            }
            when (status.status) {
                "completed" -> return status.url ?: run { setPhase(key, UploadPhase.Failed(null)); null }
                "failed" -> { setPhase(key, UploadPhase.Failed(status.error)); return null }
                else -> status.step?.let { setPhase(key, UploadPhase.Step(it)) }
            }
        }
        setPhase(key, UploadPhase.TimedOut)
        return null
    }

    private fun insertUrl(url: String) {
        val current = text.value.text
        val result = TextInsert.insert(current, insertionPoint ?: current.length, url)
        insertionPoint = result.caret
        text.value = TextFieldValue(result.text, TextRange(result.caret))
        saveDraft(result.text)
    }

    private suspend fun mediaSettings(): MediaSettings {
        container.me.value?.let { return it.user.settings.media }
        return runCatching { container.api.me().also(container::setMe).user.settings.media }.getOrDefault(MediaSettings())
    }

    private suspend fun limit(): Long =
        uploadLimit ?: runCatching { container.api.meta().limits.uploadMaxBytes }.getOrDefault(DEFAULT_LIMIT).also { uploadLimit = it }

    private fun track(line: UploadLine) = ui.update { it.copy(uploads = it.uploads + line) }

    private fun setPhase(key: Int, phase: UploadPhase) = ui.update { s ->
        s.copy(uploads = s.uploads.map { if (it.key == key) it.copy(phase = phase) else it })
    }

    private fun setNote(key: Int, note: UploadNote) = ui.update { s ->
        s.copy(uploads = s.uploads.map { if (it.key == key) it.copy(note = note) else it })
    }

    private fun rename(key: Int, name: String) = ui.update { s ->
        s.copy(uploads = s.uploads.map { if (it.key == key) it.copy(name = name) else it })
    }

    fun dismissUpload(key: Int) = ui.update { s -> s.copy(uploads = s.uploads.filterNot { it.key == key }) }

    // --- AI --------------------------------------------------------------------------

    fun generate(prompt: String) {
        val accountId = ui.value.accountId ?: return
        runAi(refining = false) { container.api.generateStream(accountId, prompt.trim(), null) }
    }

    fun refine(instruction: String) {
        val accountId = ui.value.accountId ?: return
        val current = text.value.text.trim()
        runAi(refining = true) { container.api.refineStream(accountId, current, instruction.trim()) }
    }

    fun cancelAi() {
        aiJob?.cancel()
        ui.update { it.copy(ai = it.ai.copy(running = false)) }
    }

    fun undoAi() {
        val previous = ui.value.ai.replaced ?: return
        setText(previous)
        ui.update { it.copy(ai = it.ai.copy(replaced = null)) }
    }

    private fun runAi(refining: Boolean, stream: () -> kotlinx.coroutines.flow.Flow<SseEvent>) {
        aiJob?.cancel()
        ui.update { it.copy(ai = AiState(running = true, refining = refining, phase = "connecting")) }
        aiJob = viewModelScope.launch {
            var final: String? = null
            try {
                stream().collect { event ->
                    when (event.event) {
                        "phase" -> {
                            val phase = runCatching { AppJson.parseToJsonElement(event.data).jsonObject["phase"]?.jsonPrimitive?.contentOrNull }.getOrNull()
                            // The humanize pass rewrites the draft from scratch; start the preview over.
                            ui.update { s -> s.copy(ai = s.ai.copy(phase = phase, preview = if (phase == "humanizing") "" else s.ai.preview)) }
                        }
                        "chunk" -> {
                            val chunk = runCatching { AppJson.decodeFromString(String.serializer(), event.data) }.getOrDefault(event.data)
                            ui.update { s -> s.copy(ai = s.ai.copy(preview = s.ai.preview + chunk)) }
                        }
                        "complete" -> final = runCatching {
                            AppJson.parseToJsonElement(event.data).jsonObject["content"]?.jsonPrimitive?.contentOrNull
                        }.getOrNull()
                        "error" -> {
                            val message = runCatching {
                                AppJson.parseToJsonElement(event.data).jsonObject["message"]?.jsonPrimitive?.contentOrNull
                            }.getOrNull()
                            ui.update { s -> s.copy(ai = s.ai.copy(running = false, error = message ?: "")) }
                        }
                    }
                }
                val result = final ?: ui.value.ai.preview.takeIf { it.isNotBlank() && ui.value.ai.error == null }
                if (result != null) {
                    val previous = text.value.text
                    setText(result)
                    ui.update { s -> s.copy(ai = s.ai.copy(running = false, completed = true, replaced = previous.takeIf { it.isNotBlank() })) }
                } else if (ui.value.ai.error == null) {
                    ui.update { s -> s.copy(ai = s.ai.copy(running = false, error = "")) }
                }
            } catch (e: ApiException) {
                ui.update { s -> s.copy(ai = s.ai.copy(running = false, error = e.message, paywall = e.code == "paywall")) }
            }
        }
    }

    // --- saving ------------------------------------------------------------------------

    /** Save, then go to scheduling (or to the post page with [toSchedule] false). */
    fun save(toSchedule: Boolean) {
        val state = ui.value
        if (state.saving || state.uploading) return
        val accountId = state.accountId ?: return
        ui.update { it.copy(saving = true, error = null) }
        viewModelScope.launch {
            try {
                val content = text.value.text
                val post = if (postId == null) container.api.createPost(accountId, content).post
                else container.api.updatePost(postId, content).post
                clearDraft()
                container.prefs.lastAccountId = accountId
                ui.update { it.copy(saving = false) }
                events.send(if (toSchedule && post.can.schedule) ComposeEvent.Schedule(post.id) else ComposeEvent.Open(post.id))
            } catch (e: ApiException) {
                ui.update { it.copy(saving = false, error = e.message) }
            }
        }
    }

    private companion object {
        const val POLL_TIMEOUT_MS = 6 * 60 * 1000L
        const val DONE_VISIBLE_MS = 4000L
        const val DEFAULT_LIMIT = 99L * 1024 * 1024
    }
}
