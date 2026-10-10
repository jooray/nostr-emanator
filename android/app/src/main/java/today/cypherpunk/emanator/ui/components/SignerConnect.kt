package today.cypherpunk.emanator.ui.components

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import today.cypherpunk.emanator.R
import today.cypherpunk.emanator.ui.theme.LocalConsole
import today.cypherpunk.emanator.ui.theme.Palette
import today.cypherpunk.emanator.ui.theme.Type
import today.cypherpunk.emanator.util.Links
import today.cypherpunk.emanator.util.Qr

/** Where a NIP-46 connection attempt stands, for login and pairing alike. */
sealed interface ConnectState {
    data object Idle : ConnectState
    data object Starting : ConnectState
    data class Waiting(val uri: String?, val authUrl: String? = null) : ConnectState
    data object Expired : ConnectState
    data class Failed(val message: String) : ConnectState
}

/**
 * Hands a nostrconnect:// URI to the signer. With Amber on this phone that is
 * one tap — no QR involved; a signer on another device scans the QR instead.
 * With no signer on this phone the code is created and its QR shown at once:
 * there is nothing to tap through to.
 * The QR carries the same phishing warning as the web: scanning a code someone
 * else shows you hands them your session.
 */
@Composable
fun SignerConnect(
    state: ConnectState,
    pairing: Boolean,
    onStart: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val c = LocalConsole.current
    val noSigner = remember { !Links.canOpenSigner(context, "nostrconnect://") }
    var showQr by rememberSaveable { mutableStateOf(noSigner) }
    var autoStarted by rememberSaveable { mutableStateOf(false) }
    if (noSigner && state == ConnectState.Idle && !autoStarted) {
        LaunchedEffect(Unit) { autoStarted = true; onStart() }
    }

    Column(modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(14.dp)) {
        when (state) {
            ConnectState.Idle, ConnectState.Starting -> {
                PrimaryButton(stringResource(R.string.signer_open), onStart, Modifier.fillMaxWidth(), busy = state == ConnectState.Starting)
                Text(stringResource(R.string.signer_open_hint), style = Type.small, color = c.muted)
            }
            is ConnectState.Waiting -> {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    CircularProgressIndicator(Modifier.size(18.dp), color = Palette.amber, strokeWidth = 2.dp)
                    Text(stringResource(R.string.signer_waiting), style = Type.bodyDense, color = c.text)
                }
                state.authUrl?.let { url ->
                    WaitBlock(stringResource(R.string.signer_auth_challenge)) {
                        SlugButton(stringResource(R.string.signer_open_approval), { Links.openUrl(context, url) }, tone = SlugTone.Wait)
                    }
                }
                state.uri?.let { uri ->
                    if (Links.canOpenSigner(context, uri)) {
                        PrimaryButton(stringResource(R.string.signer_open), { Links.openSigner(context, uri) }, Modifier.fillMaxWidth())
                    } else {
                        NoteBlock(stringResource(R.string.signer_none_installed))
                    }
                    SecondaryButton(
                        stringResource(if (showQr) R.string.signer_hide_qr else R.string.signer_scan_hint),
                        { showQr = !showQr },
                        Modifier.fillMaxWidth(),
                    )
                    if (showQr) {
                        val bitmap = remember(uri) { Qr.bitmap(uri).asImageBitmap() }
                        Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.fillMaxWidth()) {
                            Image(bitmap, contentDescription = null, modifier = Modifier.size(260.dp).background(Palette.paperWhite).padding(8.dp))
                        }
                        WaitBlock(stringResource(if (pairing) R.string.signer_qr_warning_pairing else R.string.signer_qr_warning_login))
                        SlugButton(stringResource(R.string.action_copy), { Links.copy(context, "nostrconnect", uri) })
                    }
                }
                Text(stringResource(R.string.signer_stale), style = Type.small, color = c.muted)
                SlugButton(stringResource(R.string.signer_new_code), onStart)
            }
            ConnectState.Expired -> {
                NoteBlock(stringResource(R.string.signer_expired))
                PrimaryButton(stringResource(R.string.signer_new_code), onStart, Modifier.fillMaxWidth())
            }
            is ConnectState.Failed -> {
                AlarmBlock(state.message)
                PrimaryButton(stringResource(R.string.signer_new_code), onStart, Modifier.fillMaxWidth())
            }
        }
    }
}
