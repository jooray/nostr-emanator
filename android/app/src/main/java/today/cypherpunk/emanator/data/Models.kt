package today.cypherpunk.emanator.data

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonObject

// Shapes of /api/v1, field for field with app/serializers/api_serializer.rb on
// the server. Times are ISO8601 UTC strings; parse with util.Times.

@Serializable
data class Meta(
    @SerialName("api_version") val apiVersion: Int,
    val name: String = "Emanator",
    @SerialName("canonical_url") val canonicalUrl: String? = null,
    val locales: List<String> = emptyList(),
    @SerialName("billing_enabled") val billingEnabled: Boolean = false,
    val android: ReleaseInfo = ReleaseInfo(),
    val limits: Limits = Limits(),
)

@Serializable
data class ReleaseInfo(
    @SerialName("min_version_code") val minVersionCode: Int = 0,
    @SerialName("latest_version_code") val latestVersionCode: Int = 0,
    @SerialName("latest_version_name") val latestVersionName: String = "",
    @SerialName("download_url") val downloadUrl: String? = null,
    @SerialName("zapstore_url") val zapstoreUrl: String? = null,
)

@Serializable
data class Limits(
    @SerialName("upload_max_bytes") val uploadMaxBytes: Long = 99L * 1024 * 1024,
    @SerialName("personality_max_length") val personalityMaxLength: Int = 8000,
)

// --- auth -----------------------------------------------------------------------

@Serializable
data class ConnectSession(
    @SerialName("session_id") val sessionId: String,
    @SerialName("poll_token") val pollToken: String? = null,
    val uri: String? = null,
    val relays: List<String> = emptyList(),
    @SerialName("expires_in") val expiresIn: Int = 300,
)

@Serializable
data class LoginChallenge(val challenge: String, val domain: String, @SerialName("token_url") val tokenUrl: String? = null)

/** A poll answer, and also what /auth/token answers (without a status). */
@Serializable
data class LoginPoll(
    val status: String = "authenticated",
    @SerialName("auth_url") val authUrl: String? = null,
    val token: String? = null,
    val user: User? = null,
)

// --- people ---------------------------------------------------------------------

@Serializable
data class MediaSettings(
    val compress: Boolean = true,
    @SerialName("max_edge") val maxEdge: Int = 2048,
    val quality: Int = 85,
    @SerialName("photo_format") val photoFormat: String = "jpeg",
    @SerialName("video_compress") val videoCompress: Boolean = true,
    @SerialName("video_resolution") val videoResolution: Int = 1080,
    @SerialName("video_quality") val videoQuality: String = "balanced",
)

@Serializable
data class UserSettings(
    val locale: String? = null,
    val timezone: String = "UTC",
    val theme: String = "system",
    @SerialName("event_viewer") val eventViewer: String = "njump",
    @SerialName("custom_relays") val customRelays: List<String> = emptyList(),
    val media: MediaSettings = MediaSettings(),
)

@Serializable
data class User(
    val id: Long,
    val npub: String,
    @SerialName("pubkey_hex") val pubkeyHex: String,
    @SerialName("display_name") val displayName: String? = null,
    val username: String? = null,
    val about: String? = null,
    @SerialName("picture_url") val pictureUrl: String? = null,
    val name: String,
    val settings: UserSettings = UserSettings(),
)

@Serializable
data class Summary(
    val identities: Int = 0,
    val waiting: Int = 0,
    val short: Int = 0,
    val failed: Int = 0,
    @SerialName("unread_messages") val unreadMessages: Int = 0,
    @SerialName("has_requests") val hasRequests: Boolean = false,
)

@Serializable
data class DeviceRef(val id: Long, val name: String)

@Serializable
data class Me(
    val user: User,
    val summary: Summary = Summary(),
    @SerialName("billing_enabled") val billingEnabled: Boolean = false,
    val device: DeviceRef? = null,
)

@Serializable
data class AccountMini(
    val id: Long,
    val name: String,
    val username: String? = null,
    @SerialName("picture_url") val pictureUrl: String? = null,
    val npub: String? = null,
    val ink: String = "#7a8085",
    val chop: String = "?",
    @SerialName("has_signer") val hasSigner: Boolean = false,
)

@Serializable
data class AccountCounts(
    val total: Int = 0,
    val draft: Int = 0,
    val published: Int = 0,
    val failed: Int = 0,
    val upcoming: Int = 0,
)

@Serializable
data class Account(
    val id: Long,
    val name: String,
    val username: String? = null,
    @SerialName("picture_url") val pictureUrl: String? = null,
    val npub: String? = null,
    val ink: String = "#7a8085",
    val chop: String = "?",
    @SerialName("has_signer") val hasSigner: Boolean = false,
    @SerialName("pubkey_hex") val pubkeyHex: String,
    @SerialName("display_name") val displayName: String? = null,
    val about: String? = null,
    val personality: String? = null,
    @SerialName("write_relays") val writeRelays: List<String> = emptyList(),
    @SerialName("read_relays") val readRelays: List<String> = emptyList(),
    @SerialName("signer_relay") val signerRelay: String? = null,
    @SerialName("blossom_server") val blossomServer: String? = null,
    @SerialName("blossom_server_override") val blossomServerOverride: String? = null,
    @SerialName("default_blossom_server") val defaultBlossomServer: String? = null,
    @SerialName("messaging_capable") val messagingCapable: Boolean = false,
    @SerialName("needs_messaging_repair") val needsMessagingRepair: Boolean = false,
    @SerialName("messaging_denied") val messagingDenied: Boolean = false,
    @SerialName("relay_auth_blocked") val relayAuthBlocked: Boolean = false,
    @SerialName("relay_auth_blocked_relay") val relayAuthBlockedRelay: String? = null,
    @SerialName("profile_editing_capable") val profileEditingCapable: Boolean = false,
    @SerialName("profile_url") val profileUrl: String? = null,
    val counts: AccountCounts? = null,
) {
    fun mini() = AccountMini(id, name, username, pictureUrl, npub, ink, chop, hasSigner)
}

@Serializable
data class AccountsResponse(val accounts: List<Account>)

@Serializable
data class AccountDetail(val account: Account, val upcoming: List<PostItem> = emptyList())

@Serializable
data class AccountResponse(val account: Account, val message: String? = null)

// --- posts ----------------------------------------------------------------------

@Serializable
data class RelayResult(val relay: String, val result: String)

@Serializable
data class Delivery(
    val grade: String = "unknown",
    val ok: Int = 0,
    val total: Int = 0,
    val tally: String? = null,
    val short: Boolean = false,
    val alarming: Boolean = false,
    val results: List<RelayResult> = emptyList(),
)

@Serializable
data class Can(
    val edit: Boolean = false,
    val schedule: Boolean = false,
    val cancel: Boolean = false,
    val reschedule: Boolean = false,
    @SerialName("retry_sign") val retrySign: Boolean = false,
    @SerialName("retry_publish") val retryPublish: Boolean = false,
    val rebroadcast: Boolean = false,
    @SerialName("publish_now") val publishNow: Boolean = false,
)

@Serializable
data class Quote(val author: String? = null, val content: String)

// A `nostr:` reference inside a text, resolved by the server. `match` is the
// exact substring to replace.
@Serializable
data class Reference(
    val match: String,
    val type: String,
    val identifier: String,
    val label: String,
    val url: String? = null,
    @SerialName("pubkey_hex") val pubkeyHex: String? = null,
    @SerialName("event_id") val eventId: String? = null,
    val quote: Quote? = null,
)

@Serializable
data class VersionEntry(val content: String, @SerialName("changed_at") val changedAt: String? = null)

@Serializable
data class ParentPostRef(val id: Long, val account: AccountMini? = null, val status: String? = null)

// One row of a list: a post or a repost (type tells which). Reposts carry
// their note's text in `content` and the note's id in `post_id`.
@Serializable
data class PostItem(
    val type: String = "post",
    val id: Long,
    @SerialName("post_id") val postId: Long? = null,
    @SerialName("account_id") val accountId: Long,
    val account: AccountMini? = null,
    val content: String? = null,
    val status: String,
    @SerialName("is_reply") val isReply: Boolean = false,
    @SerialName("reply_to_event_id") val replyToEventId: String? = null,
    @SerialName("scheduled_at") val scheduledAt: String? = null,
    @SerialName("published_at") val publishedAt: String? = null,
    @SerialName("created_at") val createdAt: String? = null,
    @SerialName("updated_at") val updatedAt: String? = null,
    @SerialName("delay_minutes") val delayMinutes: Int? = null,
    @SerialName("event_id") val eventId: String? = null,
    val nevent: String? = null,
    @SerialName("viewer_url") val viewerUrl: String? = null,
    val delivery: Delivery = Delivery(),
    val error: String? = null,
    @SerialName("reposts_count") val repostsCount: Int = 0,
    val can: Can = Can(),
    val reposts: List<PostItem> = emptyList(),
    @SerialName("version_history") val versionHistory: List<VersionEntry> = emptyList(),
    val references: List<Reference> = emptyList(),
    val post: ParentPostRef? = null,
) {
    val isRepost get() = type == "repost"
    /** The post whose page this row opens: itself, or the note a repost reposts. */
    val targetPostId get() = if (isRepost) (postId ?: post?.id ?: id) else id
}

@Serializable
data class Pagination(
    val page: Int = 1,
    @SerialName("total_pages") val totalPages: Int = 1,
    @SerialName("total_count") val totalCount: Int = 0,
    @SerialName("next_page") val nextPage: Int? = null,
)

@Serializable
data class PostsPage(
    val items: List<PostItem>,
    @SerialName("failed_here") val failedHere: Int = 0,
    val pagination: Pagination = Pagination(),
)

@Serializable
data class PostResponse(
    val post: PostItem,
    val message: String? = null,
    @SerialName("repost_account_ids") val repostAccountIds: List<Long> = emptyList(),
)

@Serializable
data class ScheduleOptions(
    @SerialName("suggested_at") val suggestedAt: String? = null,
    @SerialName("soon_minutes") val soonMinutes: Int = 7,
    @SerialName("default_max_delay_hours") val defaultMaxDelayHours: Int = 1,
    @SerialName("max_delay_hours") val maxDelayHours: Int = 8760,
    @SerialName("repost_accounts") val repostAccounts: List<AccountMini> = emptyList(),
    @SerialName("existing_repost_account_ids") val existingRepostAccountIds: List<Long> = emptyList(),
)

@Serializable
data class DiscardResult(val discarded: Int, val message: String? = null)

@Serializable
data class Dashboard(
    @SerialName("has_accounts") val hasAccounts: Boolean = false,
    val waiting: List<PostItem> = emptyList(),
    val unreached: List<PostItem> = emptyList(),
    val upcoming: List<PostItem> = emptyList(),
    val failed: List<PostItem> = emptyList(),
    @SerialName("failed_total") val failedTotal: Int = 0,
    val recent: List<PostItem> = emptyList(),
    @SerialName("held_count") val heldCount: Int = 0,
    val summary: Summary = Summary(),
)

@Serializable
data class CalendarResponse(val from: String? = null, val to: String? = null, val items: List<PostItem> = emptyList())

// --- interactions -----------------------------------------------------------------

@Serializable
data class Person(
    @SerialName("pubkey_hex") val pubkeyHex: String? = null,
    val npub: String? = null,
    val name: String? = null,
    @SerialName("picture_url") val pictureUrl: String? = null,
    @SerialName("profile_url") val profileUrl: String? = null,
)

@Serializable
data class OriginalPost(
    val content: String,
    val owned: Boolean = false,
    @SerialName("post_id") val postId: Long? = null,
    @SerialName("event_id") val eventId: String? = null,
    @SerialName("author_name") val authorName: String? = null,
    @SerialName("author_pubkey") val authorPubkey: String? = null,
    @SerialName("viewer_url") val viewerUrl: String? = null,
)

@Serializable
data class Interaction(
    @SerialName("event_id") val eventId: String,
    val type: String,
    val content: String? = null,
    @SerialName("created_at") val createdAt: String? = null,
    val author: Person = Person(),
    val account: AccountMini? = null,
    @SerialName("relay_hint") val relayHint: String? = null,
    @SerialName("root_event_id") val rootEventId: String? = null,
    @SerialName("already_following") val alreadyFollowing: Boolean = false,
    @SerialName("already_liked") val alreadyLiked: Boolean = false,
    val nevent: String? = null,
    @SerialName("viewer_url") val viewerUrl: String? = null,
    val original: OriginalPost? = null,
    val references: List<Reference> = emptyList(),
)

@Serializable
data class InteractionsResponse(
    val interactions: List<Interaction> = emptyList(),
    val refreshing: Boolean = false,
    val loaded: Boolean = false,
)

@Serializable
data class NostrEvent(
    val id: String? = null,
    val content: String? = null,
    @SerialName("created_at") val createdAt: String? = null,
    val nevent: String? = null,
    @SerialName("viewer_url") val viewerUrl: String? = null,
    val references: List<Reference> = emptyList(),
)

@Serializable
data class EventsResponse(val events: List<NostrEvent> = emptyList())

@Serializable
data class NostrActionResult(
    val id: Long,
    val status: String,
    @SerialName("action_type") val actionType: String,
    val error: String? = null,
)

// --- messaging -----------------------------------------------------------------------

@Serializable
data class Conversation(
    val id: Long,
    val account: AccountMini? = null,
    val title: String,
    val subject: String? = null,
    val peers: List<Person> = emptyList(),
    val protocol: String = "nip17",
    val legacy: Boolean = false,
    val group: Boolean = false,
    val classification: String = "known",
    @SerialName("classification_reason") val classificationReason: String? = null,
    @SerialName("classification_badge") val classificationBadge: String? = null,
    @SerialName("unread_count") val unreadCount: Int = 0,
    @SerialName("last_message_at") val lastMessageAt: String? = null,
    @SerialName("last_message_preview") val lastMessagePreview: String? = null,
    @SerialName("last_message_from_self") val lastMessageFromSelf: Boolean = false,
)

@Serializable
data class SyncState(
    @SerialName("account_id") val accountId: Long,
    val status: String = "idle",
    val step: String? = null,
    @SerialName("last_synced_at") val lastSyncedAt: String? = null,
    @SerialName("pending_wraps") val pendingWraps: Int = 0,
)

@Serializable
data class BlockedAccount(
    val id: Long,
    val name: String,
    val relay: String? = null,
)

@Serializable
data class TabCounts(val known: Int = 0, val requests: Int = 0)

@Serializable
data class Inbox(
    val tab: String = "known",
    @SerialName("account_filter") val accountFilter: List<Long> = emptyList(),
    val counts: TabCounts = TabCounts(),
    val conversations: List<Conversation> = emptyList(),
    val pagination: Pagination = Pagination(),
    @SerialName("accounts_needing_repair") val accountsNeedingRepair: List<AccountMini> = emptyList(),
    @SerialName("accounts_relay_auth_blocked") val accountsRelayAuthBlocked: List<BlockedAccount> = emptyList(),
    val sync: List<SyncState> = emptyList(),
)

@Serializable
data class Message(
    val id: Long,
    @SerialName("conversation_id") val conversationId: Long,
    val direction: String,
    val kind: Int = 14,
    val legacy: Boolean = false,
    val file: Boolean = false,
    val content: String? = null,
    val subject: String? = null,
    val sender: Person = Person(),
    @SerialName("sent_at") val sentAt: String? = null,
    val status: String,
    val sending: Boolean = false,
    val step: String? = null,
    val error: String? = null,
    @SerialName("can_retry") val canRetry: Boolean = false,
    @SerialName("delivery_tier") val deliveryTier: String? = null,
    @SerialName("delivery_note") val deliveryNote: String? = null,
    @SerialName("legacy_downgrade") val legacyDowngrade: Boolean = false,
    @SerialName("reply_to_rumor_id") val replyToRumorId: String? = null,
    @SerialName("rumor_id") val rumorId: String? = null,
    val references: List<Reference> = emptyList(),
) {
    /** Rails sends the enum key: "outbound" / "inbound". */
    val outbound get() = direction == "outbound"
}

@Serializable
data class Thread(
    val conversation: Conversation,
    val messages: List<Message> = emptyList(),
    @SerialName("has_more") val hasMore: Boolean = false,
    val delivery: String = "checking",
    @SerialName("legacy_downgrade_risks") val legacyDowngradeRisks: List<String> = emptyList(),
)

@Serializable
data class ConversationResponse(val conversation: Conversation, val message: String? = null)

@Serializable
data class SentMessage(val message: Message, @SerialName("conversation_id") val conversationId: Long? = null)

@Serializable
data class Cleared(val cleared: Int)

// --- uploads, billing, settings -----------------------------------------------------

@Serializable
data class Upload(
    val id: Long,
    val status: String,
    val step: String? = null,
    val url: String? = null,
    val error: String? = null,
    val filename: String? = null,
)

@Serializable
data class Plan(val id: String, val sats: Long, val days: Int)

@Serializable
data class OtherProduct(val product: String, val state: String, val until: String? = null)

@Serializable
data class Settled(val plan: String? = null, @SerialName("invoice_id") val invoiceId: String? = null)

@Serializable
data class Billing(
    val enabled: Boolean = false,
    val product: String = "emanator-ai",
    val state: String = "unknown",
    val until: String? = null,
    @SerialName("allows_ai") val allowsAi: Boolean = false,
    val others: List<OtherProduct> = emptyList(),
    val plans: List<Plan>? = null,
    @SerialName("min_sats") val minSats: Long = 1000,
    @SerialName("max_sats") val maxSats: Long = 1_000_000,
    @SerialName("free_account_limit") val freeAccountLimit: Int = 10,
    val settled: Settled? = null,
)

@Serializable
data class Checkout(@SerialName("checkout_url") val checkoutUrl: String, @SerialName("invoice_id") val invoiceId: String? = null)

@Serializable
data class Device(
    val id: Long,
    val name: String,
    @SerialName("client_version") val clientVersion: String? = null,
    @SerialName("created_at") val createdAt: String? = null,
    @SerialName("last_used_at") val lastUsedAt: String? = null,
    val current: Boolean = false,
)

@Serializable
data class DevicesResponse(val devices: List<Device> = emptyList())

@Serializable
data class McpToken(
    val id: Long,
    val name: String,
    val preview: String? = null,
    @SerialName("created_at") val createdAt: String? = null,
    @SerialName("expires_at") val expiresAt: String? = null,
    val expired: Boolean = false,
    @SerialName("last_used_at") val lastUsedAt: String? = null,
    val token: String? = null,
)

@Serializable
data class McpTokens(
    val endpoint: String? = null,
    @SerialName("expiry_options_days") val expiryOptionsDays: List<Int> = listOf(30, 90, 180, 365, 0),
    val tokens: List<McpToken> = emptyList(),
)

@Serializable
data class ProfileUpdateStatus(val id: Long? = null, val status: String, val step: String? = null, val error: String? = null)

@Serializable
data class ProfileResponse(
    val profile: JsonObject = JsonObject(emptyMap()),
    @SerialName("editable_fields") val editableFields: List<String> = emptyList(),
    val capable: Boolean = false,
    val pending: ProfileUpdateStatus? = null,
)

@Serializable
data class PairingStatus(
    val status: String,
    @SerialName("auth_url") val authUrl: String? = null,
    val error: String? = null,
    val account: Account? = null,
)

@Serializable
data class OkMessage(val ok: Boolean = true, val message: String? = null)

/** One @mention suggestion (ApiSerializer#mention). [mention] is the text to insert. */
@Serializable
data class Mention(
    val pubkey: String,
    val npub: String,
    val name: String? = null,
    @SerialName("display_name") val displayName: String? = null,
    val nip05: String? = null,
    @SerialName("picture_url") val pictureUrl: String? = null,
    val own: Boolean = false,
    @SerialName("account_id") val accountId: Long? = null,
    val mention: String,
) {
    val label: String get() = displayName?.takeIf { it.isNotBlank() } ?: name?.takeIf { it.isNotBlank() } ?: npub.take(16)
}

@Serializable
data class MentionsResponse(val mentions: List<Mention> = emptyList())
