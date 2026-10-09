package today.cypherpunk.emanator.ui

/** Every destination, with builders so call sites never format paths by hand. */
object Routes {
    const val DASHBOARD = "dashboard"
    const val POSTS = "posts?status={status}&account={account}"
    const val CALENDAR = "calendar"
    const val MESSAGES = "messages"
    const val MORE = "more"

    const val POST = "post/{id}"
    const val COMPOSE = "compose?account={account}&post={post}&shared={shared}"
    const val SCHEDULE = "schedule/{id}?reposts={reposts}"
    const val CONVERSATION = "conversation/{id}"
    const val INTERACTIONS = "interactions"
    const val ACCOUNTS = "accounts"
    const val ACCOUNT = "account/{id}"
    const val ACCOUNT_EDIT = "account/{id}/edit"
    const val ACCOUNT_PROFILE = "account/{id}/profile"
    const val PAIR = "pair?account={account}&reason={reason}"
    const val SETTINGS = "settings"
    const val BILLING = "billing"
    const val DEVICES = "devices"
    const val MCP_TOKENS = "mcp_tokens"

    fun posts(status: String? = null, account: Long? = null) = "posts?status=${status.orEmpty()}&account=${account ?: 0}"
    fun post(id: Long) = "post/$id"
    fun compose(account: Long? = null, post: Long? = null, shared: Boolean = false) =
        "compose?account=${account ?: 0}&post=${post ?: 0}&shared=$shared"
    fun schedule(id: Long, reposts: List<Long> = emptyList()) = "schedule/$id?reposts=${reposts.joinToString(",")}"
    fun conversation(id: Long) = "conversation/$id"
    fun account(id: Long) = "account/$id"
    fun accountEdit(id: Long) = "account/$id/edit"
    fun accountProfile(id: Long) = "account/$id/profile"
    /** account = re-pair that account; reason = "messaging" for the DM permission grant. */
    fun pair(account: Long? = null, reason: String? = null) = "pair?account=${account ?: 0}&reason=${reason.orEmpty()}"
}
