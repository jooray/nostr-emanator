package today.cypherpunk.emanator.data

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.serialization.KSerializer

/**
 * What a screen shows: the data it has (possibly the cached copy), whether a
 * refresh is running, and the last error. Data and error coexist — a failed
 * refresh keeps showing the cached copy with a quiet notice instead of
 * blanking the screen.
 */
data class Loadable<T>(
    val data: T? = null,
    val loading: Boolean = false,
    val error: ApiException? = null,
    val fromCache: Boolean = false,
)

/** Emits the cached copy (if any), then the fresh answer, storing it. */
fun <T> cachedFlow(
    cache: ResponseCache,
    key: String,
    serializer: KSerializer<T>,
    fetch: suspend () -> T,
): Flow<Loadable<T>> = flow {
    val generation = cache.generation()
    val cached = cache.read(key, serializer)
    emit(Loadable(data = cached, loading = true, fromCache = cached != null))
    try {
        val fresh = fetch()
        cache.write(key, serializer, fresh, since = generation)
        emit(Loadable(data = fresh, loading = false))
    } catch (e: ApiException) {
        emit(Loadable(data = cached, loading = false, error = e, fromCache = cached != null))
    }
}
