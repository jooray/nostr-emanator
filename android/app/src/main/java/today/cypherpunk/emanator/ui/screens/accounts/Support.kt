package today.cypherpunk.emanator.ui.screens.accounts

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.selection.selectable
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.RadioButtonDefaults
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.KSerializer
import today.cypherpunk.emanator.R
import today.cypherpunk.emanator.data.ApiException
import today.cypherpunk.emanator.data.Loadable
import today.cypherpunk.emanator.data.ResponseCache
import today.cypherpunk.emanator.data.cachedFlow
import today.cypherpunk.emanator.ui.components.Gutter
import today.cypherpunk.emanator.ui.components.Rule
import today.cypherpunk.emanator.ui.theme.LocalConsole
import today.cypherpunk.emanator.ui.theme.Palette
import today.cypherpunk.emanator.ui.theme.Type

/**
 * One screen's read: renders the copy on the phone, then the server's. `load`
 * may be called again (pull to refresh, coming back to the screen); a running
 * load is replaced, never stacked.
 */
class LoadVm<T>(
    private val cache: ResponseCache,
    private val key: String,
    private val serializer: KSerializer<T>,
    private val fetch: suspend () -> T,
) : ViewModel() {
    private val _state = MutableStateFlow(Loadable<T>())
    val state: StateFlow<Loadable<T>> = _state.asStateFlow()
    private var job: Job? = null

    fun load() {
        job?.cancel()
        job = viewModelScope.launch {
            cachedFlow(cache, key, serializer, fetch).collect { fresh ->
                // Keep what is on screen while a refresh starts, instead of
                // flashing back to the (older) disk copy.
                val current = _state.value.data
                _state.value = if (fresh.loading && current != null) fresh.copy(data = current) else fresh
            }
        }
    }

    /** Replace what is shown after an action answered with the new state. */
    fun set(value: T) {
        _state.value = Loadable(data = value)
        viewModelScope.launch { cache.write(key, serializer, value) }
    }
}

/** Runs an action, showing the server's (already localized) error in the snackbar. */
suspend fun <T> withSnackbar(snackbar: SnackbarHostState, block: suspend () -> T): T? = try {
    block()
} catch (e: ApiException) {
    snackbar.showSnackbar(e.message)
    null
}

@Composable
fun ConfirmDialog(text: String, confirmLabel: String, onConfirm: () -> Unit, onDismiss: () -> Unit, danger: Boolean = true) {
    val c = LocalConsole.current
    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = c.panel,
        text = { Text(text, style = Type.bodyDense, color = c.text) },
        confirmButton = {
            TextButton(onClick = { onDismiss(); onConfirm() }) {
                Text(confirmLabel.uppercase(), style = Type.label, color = if (danger) c.redText else c.amberText)
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text(stringResource(R.string.action_cancel).uppercase(), style = Type.label, color = c.legend) }
        },
    )
}

/** A full-width row that navigates somewhere. */
@Composable
fun NavRow(label: String, onClick: () -> Unit, modifier: Modifier = Modifier, detail: String? = null) {
    val c = LocalConsole.current
    Row(
        modifier.fillMaxWidth().clickable(onClick = onClick).padding(horizontal = Gutter, vertical = 16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(label.uppercase(), style = Type.title, color = c.text)
            detail?.let { Text(it, style = Type.small, color = c.muted) }
        }
        Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null, tint = c.muted)
    }
    Rule()
}

/** A single choice from a short list, as engraved radio rows. */
@Composable
fun <T> ChoiceList(options: List<Pair<T, String>>, selected: T, onSelect: (T) -> Unit, enabled: Boolean = true) {
    val c = LocalConsole.current
    Column {
        options.forEach { (value, label) ->
            Row(
                Modifier.fillMaxWidth()
                    .selectable(selected = value == selected, enabled = enabled, role = Role.RadioButton) { onSelect(value) }
                    .padding(vertical = 2.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                RadioButton(
                    selected = value == selected, onClick = null, enabled = enabled,
                    colors = RadioButtonDefaults.colors(selectedColor = Palette.amber, unselectedColor = c.muted),
                )
                Text(label, style = Type.bodyDense, color = c.text, modifier = Modifier.padding(start = 10.dp))
            }
        }
    }
}

/** A labelled text field with an optional help line under it. */
@Composable
fun Field(
    label: String,
    value: String,
    onChange: (String) -> Unit,
    modifier: Modifier = Modifier,
    help: String? = null,
    placeholder: String? = null,
    singleLine: Boolean = true,
    minLines: Int = 1,
    keyboardType: KeyboardType = KeyboardType.Text,
    isError: Boolean = false,
    enabled: Boolean = true,
) {
    val c = LocalConsole.current
    Column(modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        OutlinedTextField(
            value = value,
            onValueChange = onChange,
            label = { Text(label) },
            placeholder = placeholder?.let { { Text(it, color = c.muted) } },
            singleLine = singleLine,
            minLines = minLines,
            isError = isError,
            enabled = enabled,
            keyboardOptions = KeyboardOptions(keyboardType = keyboardType),
            textStyle = Type.bodyDense,
            modifier = Modifier.fillMaxWidth(),
        )
        help?.let { Text(it, style = Type.small, color = c.muted) }
    }
}

/** "npub1abcd…wxyz" — the web's short form. */
fun shortNpub(npub: String?): String =
    if (npub == null || npub.length < 20) npub.orEmpty() else "${npub.take(12)}…${npub.takeLast(4)}"
