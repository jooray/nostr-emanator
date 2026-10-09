package today.cypherpunk.emanator.util

import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.browser.customtabs.CustomTabsIntent

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

    /**
     * A note or profile: handed to whichever Nostr app is installed as a
     * `nostr:` URI (NIP-21), else opened in the user's event viewer.
     */
    fun openNostr(context: Context, identifier: String?, fallbackUrl: String?) {
        if (identifier != null) {
            val intent = Intent(Intent.ACTION_VIEW, Uri.parse("nostr:$identifier")).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            if (intent.resolveActivity(context.packageManager) != null) {
                runCatching { context.startActivity(intent); return }
            }
        }
        fallbackUrl?.let { openUrl(context, it) }
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
