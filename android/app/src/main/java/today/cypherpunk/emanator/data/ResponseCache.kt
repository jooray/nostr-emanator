package today.cypherpunk.emanator.data

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.KSerializer
import java.io.File
import java.security.MessageDigest

/**
 * The local copy every screen opens from. Each API answer a screen shows is
 * kept as JSON on disk under a key; the screen renders the copy at once and
 * then asks the server, so lists appear instantly even offline. Cleared on
 * logout — it holds the user's posts and messages.
 */
class ResponseCache(private val dir: File) {
    init { dir.mkdirs() }

    // Bumped on clear(), so a request still in flight at logout cannot write
    // the previous user's data back afterwards.
    @Volatile private var generation = 0

    private fun file(key: String): File {
        val digest = MessageDigest.getInstance("SHA-256").digest(key.toByteArray())
        return File(dir, digest.joinToString("") { "%02x".format(it) }.take(40) + ".json")
    }

    suspend fun <T> read(key: String, serializer: KSerializer<T>): T? = withContext(Dispatchers.IO) {
        val f = file(key)
        if (!f.exists()) return@withContext null
        runCatching { AppJson.decodeFromString(serializer, f.readText()) }.getOrNull()
    }

    fun generation() = generation

    suspend fun <T> write(key: String, serializer: KSerializer<T>, value: T, since: Int = generation) = withContext(Dispatchers.IO) {
        if (since != generation) return@withContext
        val f = file(key)
        val tmp = File(dir, f.name + ".tmp")
        runCatching {
            tmp.writeText(AppJson.encodeToString(serializer, value))
            tmp.renameTo(f)
        }
    }

    fun clear() {
        generation++
        dir.listFiles()?.forEach { it.delete() }
    }
}
