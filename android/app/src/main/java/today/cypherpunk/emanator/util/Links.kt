package today.cypherpunk.emanator.util

import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import androidx.browser.customtabs.CustomTabsIntent
import kotlinx.coroutines.flow.MutableStateFlow

object Links {
    /** A web page, in a Custom Tab (falls back to any browser). */
    fun openUrl(context: Context, url: String) {
        val uri = Uri.parse(url)
        try {
            CustomTabsIntent.Builder().setShowTitle(true).build().launchUrl(context, uri)
        } catch (e: ActivityNotFoundException) {
            runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, uri).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
        }
    }

    data class App(val packageName: String, val label: String)

    /** One `nostr:` link with more than one way to open it, waiting for the user to pick. */
    data class NostrChoice(val uri: String, val apps: List<App>, val webUrl: String?)

    /** Shown by [today.cypherpunk.emanator.ui.components.NostrChooser] at the root. */
    val nostrChoice = MutableStateFlow<NostrChoice?>(null)

    /** Installed apps that open a NIP-21 `nostr:` link (Amethyst, Primal, YakiHonne…), by name. */
    fun nostrApps(context: Context, uri: String): List<App> {
        val pm = context.packageManager
        return pm.queryIntentActivities(Intent(Intent.ACTION_VIEW, Uri.parse(uri)), PackageManager.MATCH_DEFAULT_ONLY)
            .map { App(it.activityInfo.packageName, it.loadLabel(pm).toString()) }
            .filter { it.packageName != context.packageName }
            .distinctBy { it.packageName }
            .sortedBy { it.label.lowercase() }
    }

    fun openInApp(context: Context, uri: String, packageName: String): Boolean = try {
        context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(uri)).setPackage(packageName).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        true
    } catch (e: ActivityNotFoundException) {
        false
    }

    /**
     * A note or profile, as a `nostr:` URI (NIP-21) in an installed Nostr app or
     * in the user's event viewer on the web. One way to open it opens it at
     * once; several ask which (the same as Lievik's "View original").
     */
    fun openNostr(context: Context, identifier: String?, fallbackUrl: String?) {
        val uri = identifier?.let { "nostr:$it" }
        val apps = uri?.let { nostrApps(context, it) }.orEmpty()
        when {
            apps.isEmpty() -> fallbackUrl?.let { openUrl(context, it) }
            apps.size == 1 && fallbackUrl == null -> openInApp(context, uri!!, apps.single().packageName)
            else -> nostrChoice.value = NostrChoice(uri!!, apps, fallbackUrl)
        }
    }

    /** True when some installed app (Amber) handles nostrconnect:// URIs. */
    fun canOpenSigner(context: Context, uri: String): Boolean =
        Intent(Intent.ACTION_VIEW, Uri.parse(uri)).resolveActivity(context.packageManager) != null

    fun openSigner(context: Context, uri: String): Boolean = try {
        context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(uri)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        true
    } catch (e: ActivityNotFoundException) {
        false
    }

    fun copy(context: Context, label: String, text: String) {
        val clipboard = context.getSystemService(ClipboardManager::class.java)
        clipboard.setPrimaryClip(ClipData.newPlainText(label, text))
    }

    fun share(context: Context, text: String) {
        val intent = Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, text)
        context.startActivity(Intent.createChooser(intent, null).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }
}
