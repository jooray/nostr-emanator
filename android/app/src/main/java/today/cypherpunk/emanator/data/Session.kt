package today.cypherpunk.emanator.data

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** Whether the app is signed in, and as whom. */
class Session(private val secure: SecureStore) {
    private val _token = MutableStateFlow(secure.get(KEY))
    val token: StateFlow<String?> = _token.asStateFlow()

    val signedIn get() = _token.value != null

    fun signIn(token: String) {
        secure.put(KEY, token)
        _token.value = token
    }

    fun signOut() {
        secure.put(KEY, null)
        _token.value = null
    }

    private companion object {
        const val KEY = "device_token"
    }
}
