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

    /** The apps Facebook and LinkedIn share text through, when they are installed. */
    const val FACEBOOK_PACKAGE = "com.facebook.katana"
    const val LINKEDIN_PACKAGE = "com.linkedin.android"

    /** Where to compose when the app is not installed (the web's behaviour). */
    const val FACEBOOK_WEB = "https://www.facebook.com/"
    const val LINKEDIN_WEB = "https://www.linkedin.com/feed/?shareActive=true"

    /** True when `packageName` is installed and handles a plain-text share. */
    fun canShareTo(context: Context, packageName: String): Boolean =
        Intent(Intent.ACTION_SEND).setType("text/plain").setPackage(packageName)
            .resolveActivity(context.packageManager) != null

    /**
     * The note into one app's composer. Facebook and LinkedIn accept no
     * prefilled text from a URL (only a link), so this is the only way to hand
     * them the text — and without the app it does what the web does: the note
     * on the clipboard, their site open, one paste away. Returns false on that
     * copy-and-open path so the caller can say so.
     */
    fun shareTextTo(context: Context, packageName: String, text: String, webUrl: String): Boolean {
        if (canShareTo(context, packageName)) {
            val direct = Intent(Intent.ACTION_SEND).setType("text/plain")
                .putExtra(Intent.EXTRA_TEXT, text).setPackage(packageName)
            if (runCatching { context.startActivity(direct.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }.isSuccess) return true
        }
        copy(context, "note", text)
        openUrl(context, webUrl)
        return false
    }

    /** x.com's compose window with `text` already in it (the X app, else a browser). */
    fun composeX(context: Context, text: String) {
        val url = "https://x.com/intent/post?text=" + Uri.encode(text)
        runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
    }

    fun share(context: Context, text: String) {
        val intent = Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, text)
        context.startActivity(Intent.createChooser(intent, null).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }
}
