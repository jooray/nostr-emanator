package today.cypherpunk.emanator.util

import android.app.LocaleManager
import android.content.Context
import android.content.res.Configuration
import android.os.Build
import android.os.LocaleList
import today.cypherpunk.emanator.data.AppPrefs
import java.util.Locale

/**
 * The interface language: en, sk, cs or es, like the web. The choice is kept
 * on the phone and on the user (so background jobs on the server write in it
 * too). On Android 13+ it is also handed to the system's per-app language
 * setting.
 */
object AppLocale {
    val SUPPORTED = listOf("en", "sk", "cs", "es")

    /** The language in effect: the app's choice, else the phone's if supported. */
    fun current(context: Context): String {
        AppPrefs(context).locale?.let { if (it in SUPPORTED) return it }
        val system = LocaleList.getDefault()
        for (i in 0 until system.size()) {
            val language = system[i].language
            if (language in SUPPORTED) return language
        }
        return "en"
    }

    fun wrap(base: Context): Context {
        val chosen = AppPrefs(base).locale ?: return base
        val locale = Locale.forLanguageTag(chosen)
        Locale.setDefault(locale)
        val config = Configuration(base.resources.configuration)
        config.setLocales(LocaleList(locale))
        return base.createConfigurationContext(config)
    }

    fun apply(context: Context, language: String?) {
        AppPrefs(context).locale = language
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.getSystemService(LocaleManager::class.java).applicationLocales =
                if (language == null) LocaleList.getEmptyLocaleList() else LocaleList.forLanguageTags(language)
        }
    }

    /** Native name of each language, as the web's switcher shows it. */
    fun displayName(code: String) = when (code) {
        "en" -> "English"
        "sk" -> "Slovenčina"
        "cs" -> "Čeština"
        "es" -> "Español"
        else -> code
    }
}
