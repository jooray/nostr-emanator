package today.cypherpunk.emanator.data

import android.content.Context
import today.cypherpunk.emanator.BuildConfig

/** Plain, non-secret preferences. */
class AppPrefs(context: Context) {
    private val prefs = context.getSharedPreferences("app", Context.MODE_PRIVATE)

    /** Which Emanator server this app talks to (self-hosters change it at login). */
    var serverUrl: String
        get() = prefs.getString("server_url", null) ?: BuildConfig.DEFAULT_SERVER
        set(value) = prefs.edit().putString("server_url", value.trim().trimEnd('/')).apply()

    /** Interface language chosen in the app; null follows the phone. */
    var locale: String?
        get() = prefs.getString("locale", null)
        set(value) = prefs.edit().putString("locale", value).apply()

    /** "system", "light" or "dark" — mirrored from the user's web setting. */
    var theme: String
        get() = prefs.getString("theme", "system") ?: "system"
        set(value) = prefs.edit().putString("theme", value).apply()

    /** The last account picked in the composer, so it is preselected next time. */
    var lastAccountId: Long
        get() = prefs.getLong("last_account_id", 0L)
        set(value) = prefs.edit().putLong("last_account_id", value).apply()

    fun clearUserState() {
        prefs.edit().remove("last_account_id").apply()
    }
}
