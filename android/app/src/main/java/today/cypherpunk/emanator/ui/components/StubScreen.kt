package today.cypherpunk.emanator.ui.components

import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.navigation.NavHostController

/** Placeholder while a screen is being built. */
@Composable
fun StubScreen(nav: NavHostController, title: String) {
    ConsoleScaffold(title, onBack = { nav.popBackStack() }) { padding ->
        EmptyState(title, Modifier.padding(padding))
    }
}
