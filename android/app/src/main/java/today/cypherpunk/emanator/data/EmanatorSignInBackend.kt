package today.cypherpunk.emanator.data

import today.cypherpunk.emanator.AppContainer
import today.cypherpunk.emanator.BuildConfig
import today.cypherpunk.nostrsignin.Challenge
import today.cypherpunk.nostrsignin.ConnectSession as SignInSession
import today.cypherpunk.nostrsignin.PollResult
import today.cypherpunk.nostrsignin.SignInBackend
import today.cypherpunk.nostrsignin.SignInUtil

/**
 * The shared sign-in module (android/nostr-signin, vendored from
 * nostr-signin-android) over Emanator's API. Failures stay [ApiException], so
 * the login screen shows the server's own (localized) message.
 */
class EmanatorSignInBackend(private val container: AppContainer) : SignInBackend {
    private val api get() = container.api
    private val device = SignInUtil.deviceName()
    private val version = BuildConfig.VERSION_CODE.toString()

    override suspend fun challenge(): Challenge = api.loginChallenge().let { Challenge(it.challenge, it.domain, it.tokenUrl) }

    override suspend fun exchangeSignedEvent(signedEventJson: String) {
        signedIn(api.loginWithSignedEvent(signedEventJson, device, version))
    }

    override suspend fun startNostrConnect(): SignInSession =
        api.startLogin().let { SignInSession(it.sessionId, it.pollToken, it.uri) }

    override suspend fun startBunker(bunkerUri: String): SignInSession =
        api.startBunkerLogin(bunkerUri).let { SignInSession(it.sessionId, it.pollToken, null) }

    override suspend fun poll(session: SignInSession): PollResult {
        val result = api.pollLogin(session.sessionId, session.pollToken, device, version)
        return when (result.status) {
            "authenticated" -> if (signedIn(result)) PollResult.Authenticated else PollResult.Expired
            "expired" -> PollResult.Expired
            else -> PollResult.Pending(result.authUrl)
        }
    }

    override fun isTransient(error: Throwable) = error is ApiException && (error.isNetwork || error.status == 429)

    private fun signedIn(result: LoginPoll): Boolean {
        val token = result.token ?: return false
        container.session.signIn(token)
        result.user?.let { container.setMe(Me(user = it)) }
        return true
    }
}
