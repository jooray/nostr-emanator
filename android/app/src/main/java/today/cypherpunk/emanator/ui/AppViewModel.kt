package today.cypherpunk.emanator.ui

import android.net.Uri
import androidx.compose.runtime.Composable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewmodel.compose.viewModel
import today.cypherpunk.emanator.AppContainer

val LocalContainer = staticCompositionLocalOf<AppContainer> { error("no AppContainer") }

/** A ViewModel built with the app's container. */
@Composable
inline fun <reified VM : ViewModel> appViewModel(key: String? = null, crossinline create: (AppContainer) -> VM): VM {
    val container = LocalContainer.current
    return viewModel(key = key) { create(container) }
}

/** What another app shared into Emanator. */
data class SharedContent(val text: String?, val uris: List<Uri>)
