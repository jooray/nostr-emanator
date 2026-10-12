package today.cypherpunk.emanator.data

import kotlinx.coroutines.flow.Flow
import java.io.File

/**
 * Every /api/v1 endpoint the app uses, typed. Mirrors config/routes.rb
 * (namespace :api / :v1) on the server.
 */
class EmanatorApi(val client: ApiClient) {
    // --- public ---------------------------------------------------------------
    suspend fun meta(): Meta = client.get("/api/v1/meta")
    suspend fun loginChallenge(): LoginChallenge = client.post("/api/v1/auth/challenge")
    suspend fun loginWithSignedEvent(signedEventJson: String, deviceName: String, clientVersion: String): LoginPoll =
        client.post("/api/v1/auth/token", mapOf("signed_event" to signedEventJson, "device_name" to deviceName, "client_version" to clientVersion))
    suspend fun startLogin(): ConnectSession = client.post("/api/v1/auth/nostrconnect")
    suspend fun startBunkerLogin(uri: String): ConnectSession = client.post("/api/v1/auth/bunker", mapOf("bunker_uri" to uri))
    suspend fun pollLogin(sessionId: String, pollToken: String?, deviceName: String, clientVersion: String): LoginPoll =
        client.post(
            "/api/v1/auth/poll",
            mapOf("session_id" to sessionId, "poll_token" to pollToken, "device_name" to deviceName, "client_version" to clientVersion),
        )
    suspend fun logout() = client.delete("/api/v1/session")

    // --- me -----------------------------------------------------------------------
    suspend fun me(): Me = client.get("/api/v1/me")
    suspend fun summary(): Summary = client.get("/api/v1/me/summary")
    suspend fun updateMe(changes: Map<String, Any?>): Me = client.patch("/api/v1/me", changes)
    suspend fun refreshMyProfile(): OkMessage = client.post("/api/v1/me/refresh_profile")
    suspend fun devices(): DevicesResponse = client.get("/api/v1/devices")
    suspend fun removeDevice(id: Long) = client.delete("/api/v1/devices/$id")
    suspend fun mcpTokens(): McpTokens = client.get("/api/v1/mcp_tokens")
    suspend fun createMcpToken(name: String, days: Int): McpToken =
        client.post("/api/v1/mcp_tokens", mapOf("name" to name, "expires_in_days" to days))
    suspend fun revokeMcpToken(id: Long) = client.delete("/api/v1/mcp_tokens/$id")

    // --- overview -----------------------------------------------------------------
    suspend fun dashboard(): Dashboard = client.get("/api/v1/dashboard")
    suspend fun calendar(from: String, to: String): CalendarResponse = client.get("/api/v1/calendar", mapOf("from" to from, "to" to to))
    suspend fun interactions(): InteractionsResponse = client.get("/api/v1/interactions")
    suspend fun mentions(query: String): MentionsResponse = client.get("/api/v1/mentions", mapOf("q" to query))

    // --- accounts -------------------------------------------------------------------
    suspend fun accounts(): AccountsResponse = client.get("/api/v1/accounts")
    suspend fun account(id: Long): AccountDetail = client.get("/api/v1/accounts/$id")
    suspend fun updateAccount(id: Long, fields: Map<String, Any?>): AccountResponse =
        client.patch("/api/v1/accounts/$id", mapOf("account" to fields))
    suspend fun removeAccount(id: Long) = client.delete("/api/v1/accounts/$id")
    suspend fun refreshAccountProfile(id: Long): OkMessage = client.post("/api/v1/accounts/$id/refresh_profile")
    suspend fun refreshAccountRelays(id: Long): OkMessage = client.post("/api/v1/accounts/$id/refresh_relays")
    suspend fun recentEvents(id: Long): EventsResponse = client.get("/api/v1/accounts/$id/recent_events")
    suspend fun recentInteractions(id: Long): InteractionsResponse = client.get("/api/v1/accounts/$id/recent_interactions")
    suspend fun profile(id: Long): ProfileResponse = client.get("/api/v1/accounts/$id/profile")
    suspend fun publishProfile(id: Long, fields: Map<String, String?>): ProfileUpdateStatus =
        client.post("/api/v1/accounts/$id/profile", mapOf("profile" to fields))
    suspend fun profileStatus(id: Long, updateId: Long): ProfileUpdateStatus =
        client.get("/api/v1/accounts/$id/profile_status", mapOf("update_id" to updateId))

    /** accountId = re-pair that account; null = pair a new one. */
    suspend fun startPairing(accountId: Long?): ConnectSession =
        client.post("/api/v1/pairings", if (accountId != null) mapOf("account_id" to accountId) else null)
    suspend fun pairingStatus(sessionId: String, accountId: Long?): PairingStatus =
        client.get("/api/v1/pairings/$sessionId", mapOf("account_id" to accountId))

    // --- posts -------------------------------------------------------------------------
    suspend fun posts(accountId: Long?, status: String?, page: Int): PostsPage =
        client.get("/api/v1/posts", mapOf("account_id" to accountId, "status" to status, "page" to page))
    suspend fun post(id: Long): PostResponse = client.get("/api/v1/posts/$id")
    suspend fun createPost(accountId: Long, content: String): PostResponse =
        client.post("/api/v1/posts", mapOf("account_id" to accountId, "post" to mapOf("content" to content)))
    suspend fun createReply(accountId: Long, content: String, replyTo: String, replyToPubkey: String?, rootEventId: String?): PostResponse =
        client.post("/api/v1/posts", mapOf("account_id" to accountId, "post" to mapOf(
            "content" to content, "is_reply" to true, "reply_to_event_id" to replyTo,
            "reply_to_pubkey" to replyToPubkey, "root_event_id" to rootEventId,
        )))
    suspend fun updatePost(id: Long, content: String): PostResponse =
        client.patch("/api/v1/posts/$id", mapOf("post" to mapOf("content" to content)))
    suspend fun deletePost(id: Long) = client.delete("/api/v1/posts/$id")
    suspend fun scheduleOptions(id: Long): ScheduleOptions = client.get("/api/v1/posts/$id/schedule_options")
    suspend fun schedulePost(id: Long, scheduledAtIso: String, repostAccountIds: List<Long>, maxDelayHours: Int): PostResponse =
        client.post("/api/v1/posts/$id/schedule", mapOf(
            "scheduled_at" to scheduledAtIso, "repost_account_ids" to repostAccountIds, "max_delay_hours" to maxDelayHours,
        ))
    suspend fun postAction(id: Long, action: String): PostResponse = client.post("/api/v1/posts/$id/$action")
    suspend fun discardFailed(accountId: Long?): DiscardResult = client.deleteFor("/api/v1/failed_posts", mapOf("account_id" to accountId))
    suspend fun repostAction(postId: Long, repostId: Long, action: String): PostResponse =
        client.post("/api/v1/posts/$postId/reposts/$repostId/$action")
    suspend fun cancelRepost(postId: Long, repostId: Long): PostResponse =
        client.deleteFor("/api/v1/posts/$postId/reposts/$repostId")

    // --- interactions: like / follow / mute -------------------------------------------------
    suspend fun nostrAction(accountId: Long, type: String, eventId: String?, pubkey: String, kind: Int? = 1): NostrActionResult =
        client.post("/api/v1/accounts/$accountId/nostr_actions", mapOf("nostr_action" to mapOf(
            "action_type" to type, "target_event_id" to eventId, "target_pubkey" to pubkey, "target_event_kind" to kind,
        )))
    suspend fun nostrActionStatus(id: Long): NostrActionResult = client.get("/api/v1/nostr_actions/$id")

    // --- messaging ------------------------------------------------------------------------
    suspend fun inbox(tab: String, unreadOnly: Boolean, page: Int, accountIds: List<Long>? = null): Inbox =
        client.get("/api/v1/conversations", buildMap {
            put("tab", tab)
            put("page", page)
            if (unreadOnly) put("unread", "1")
            // An explicit empty list means "every account" and must still be sent.
            if (accountIds != null) put("account_ids", if (accountIds.isEmpty()) listOf("") else accountIds)
        })
    suspend fun thread(id: Long, before: Long? = null): Thread = client.get("/api/v1/conversations/$id", mapOf("before" to before))
    suspend fun acceptConversation(id: Long): ConversationResponse = client.post("/api/v1/conversations/$id/accept")
    suspend fun blockConversation(id: Long): ConversationResponse = client.post("/api/v1/conversations/$id/block")
    suspend fun markRead(id: Long) = client.postUnit("/api/v1/conversations/$id/mark_read")
    suspend fun markAllRead(tab: String): Cleared = client.post("/api/v1/messages/mark_all_read", mapOf("tab" to tab))
    suspend fun sendMessage(conversationId: Long, content: String, replyTo: String?, legacyAck: Boolean): SentMessage =
        client.post("/api/v1/conversations/$conversationId/messages", mapOf(
            "content" to content, "reply_to" to replyTo, "legacy_ack" to legacyAck,
        ))
    suspend fun message(id: Long): SentMessage = client.get("/api/v1/messages/$id")
    suspend fun retryMessage(id: Long): SentMessage = client.post("/api/v1/messages/$id/retry")
    suspend fun downgradeMessage(id: Long): SentMessage = client.post("/api/v1/messages/$id/downgrade", mapOf("legacy_ack" to true))

    // --- AI -------------------------------------------------------------------------------------
    fun generateStream(accountId: Long, prompt: String, language: String?): Flow<SseEvent> =
        client.stream("/api/v1/ai/generate_stream", mapOf("account_id" to accountId, "prompt" to prompt, "language" to language))
    fun refineStream(accountId: Long, current: String, prompt: String): Flow<SseEvent> =
        client.stream("/api/v1/ai/refine_stream", mapOf("account_id" to accountId, "current_content" to current, "user_prompt" to prompt))

    // --- uploads -----------------------------------------------------------------------------
    suspend fun upload(accountId: Long, file: File, fileName: String, mimeType: String, onProgress: (Int) -> Unit = {}): Upload =
        client.upload("/api/v1/accounts/$accountId/uploads", file, fileName, mimeType, onProgress)
    suspend fun uploadStatus(id: Long): Upload = client.get("/api/v1/uploads/$id")

    // --- billing --------------------------------------------------------------------------
    suspend fun billing(): Billing = client.get("/api/v1/billing")
    suspend fun createCharge(plan: String, sats: Long?): Checkout =
        client.post("/api/v1/billing/charges", mapOf("plan" to plan, "sats" to sats))
}
