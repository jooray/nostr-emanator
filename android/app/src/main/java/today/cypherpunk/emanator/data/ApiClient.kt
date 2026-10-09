package today.cypherpunk.emanator.data

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.channelFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.withContext
import kotlinx.serialization.KSerializer
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.serializer
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.MultipartBody
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.RequestBody.Companion.asRequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import java.io.File
import java.io.IOException

val AppJson = Json {
    ignoreUnknownKeys = true
    explicitNulls = false
    encodeDefaults = true
    coerceInputValues = true
}

/**
 * An error the user can read. [message] is already localized by the server
 * (it speaks the user's language), or comes from the app's own strings for
 * network failures. [code] is the machine-readable reason.
 */
class ApiException(
    val status: Int,
    val code: String?,
    override val message: String,
    val body: JsonObject? = null,
) : Exception(message) {
    val isNetwork get() = status == 0
    val isUnauthorized get() = status == 401
    val isUpgradeRequired get() = status == 426
}

/** Hooks the HTTP layer raises into the app: lost session, outdated build. */
interface ApiEvents {
    fun onUnauthorized()
    fun onUpgradeRequired(info: ReleaseInfo)
}

/**
 * Low-level JSON over HTTP against one Emanator server. Sends the device token,
 * the app's build (X-Emanator-Client, for the server's minimum-version gate)
 * and the interface language.
 */
class ApiClient(
    val http: OkHttpClient,
    private val baseUrl: () -> String,
    private val token: () -> String?,
    private val language: () -> String,
    private val versionCode: Int,
    private val events: ApiEvents,
    private val networkErrorMessage: () -> String,
    private val unexpectedResponseMessage: () -> String,
) {
    private val jsonType = "application/json; charset=utf-8".toMediaType()

    fun url(path: String, query: Map<String, Any?> = emptyMap()): okhttp3.HttpUrl {
        val builder = (baseUrl().trimEnd('/') + path).toHttpUrl().newBuilder()
        query.forEach { (key, value) ->
            when (value) {
                null -> {}
                is Collection<*> -> value.forEach { builder.addQueryParameter("$key[]", it.toString()) }
                else -> builder.addQueryParameter(key, value.toString())
            }
        }
        return builder.build()
    }

    fun request(path: String, query: Map<String, Any?> = emptyMap()): Request.Builder {
        val builder = Request.Builder()
            .url(url(path, query))
            .header("Accept", "application/json")
            .header("X-Emanator-Client", "android/$versionCode")
            .header("Accept-Language", language())
        token()?.let { builder.header("Authorization", "Bearer $it") }
        return builder
    }

    suspend fun <T> call(request: Request, deserializer: KSerializer<T>?): T? = withContext(Dispatchers.IO) {
        val response = try {
            http.newCall(request).execute()
        } catch (e: IOException) {
            throw ApiException(0, "network", networkErrorMessage())
        }
        response.use {
            try {
                handle(it, deserializer)
            } catch (e: IOException) {
                throw ApiException(0, "network", networkErrorMessage())
            } catch (e: kotlinx.serialization.SerializationException) {
                // A captive portal or proxy answering HTML with 200.
                throw ApiException(it.code, "bad_response", unexpectedResponseMessage())
            } catch (e: IllegalArgumentException) {
                throw ApiException(it.code, "bad_response", unexpectedResponseMessage())
            }
        }
    }

    /** Raw body text of a successful response, for the on-disk cache. */
    suspend fun text(request: Request): String = withContext(Dispatchers.IO) {
        val response = try {
            http.newCall(request).execute()
        } catch (e: IOException) {
            throw ApiException(0, "network", networkErrorMessage())
        }
        response.use {
            if (!it.isSuccessful) throw errorFrom(it)
            try {
                it.body.string()
            } catch (e: IOException) {
                throw ApiException(0, "network", networkErrorMessage())
            }
        }
    }

    private fun <T> handle(response: Response, deserializer: KSerializer<T>?): T? {
        if (!response.isSuccessful) throw errorFrom(response)
        if (deserializer == null || response.code == 204) return null
        val text = response.body.string()
        return AppJson.decodeFromString(deserializer, text)
    }

    fun errorFrom(response: Response): ApiException {
        val text = runCatching { response.body.string() }.getOrDefault("")
        val body = runCatching { AppJson.parseToJsonElement(text) as? JsonObject }.getOrNull()
        // A non-JSON error (nginx 502 during a deploy) gets the app's own wording.
        val message = body?.get("error")?.jsonPrimitive?.contentOrNull ?: unexpectedResponseMessage()
        val code = body?.get("code")?.jsonPrimitive?.contentOrNull
        val error = ApiException(response.code, code, message, body)
        when (response.code) {
            401 -> if (token() != null) events.onUnauthorized()
            426 -> body?.let { events.onUpgradeRequired(AppJson.decodeFromJsonElement(ReleaseInfo.serializer(), it)) }
        }
        return error
    }

    fun jsonBody(body: Any?): RequestBody = when (body) {
        null -> "{}".toRequestBody(jsonType)
        is JsonElement -> AppJson.encodeToString(JsonElement.serializer(), body).toRequestBody(jsonType)
        is Map<*, *> -> AppJson.encodeToString(JsonElement.serializer(), toJson(body)).toRequestBody(jsonType)
        else -> error("unsupported body ${body::class}")
    }

    suspend inline fun <reified T> get(path: String, query: Map<String, Any?> = emptyMap()): T =
        call(request(path, query).get().build(), serializer<T>())!!

    suspend inline fun <reified T> post(path: String, body: Any? = null): T =
        call(request(path).post(jsonBody(body)).build(), serializer<T>())!!

    suspend inline fun <reified T> patch(path: String, body: Any? = null): T =
        call(request(path).patch(jsonBody(body)).build(), serializer<T>())!!

    suspend fun postUnit(path: String, body: Any? = null) {
        call<Unit>(request(path).post(jsonBody(body)).build(), null)
    }

    suspend fun delete(path: String, query: Map<String, Any?> = emptyMap()) {
        call<Unit>(request(path, query).delete().build(), null)
    }

    suspend inline fun <reified T> deleteFor(path: String, query: Map<String, Any?> = emptyMap()): T =
        call(request(path, query).delete().build(), serializer<T>())!!

    suspend fun upload(path: String, file: File, fileName: String, mimeType: String): Upload {
        val multipart = MultipartBody.Builder().setType(MultipartBody.FORM)
            .addFormDataPart("file", fileName, file.asRequestBody(mimeType.toMediaType()))
            .build()
        return call(request(path).post(multipart).build(), Upload.serializer())!!
    }

    /**
     * Server-sent events from a POST (the AI streams). Denials arrive as plain
     * JSON errors before any event and are thrown as [ApiException].
     */
    fun stream(path: String, body: Map<String, Any?>): Flow<SseEvent> = channelFlow {
        val request = request(path).header("Accept", "text/event-stream").post(jsonBody(body)).build()
        val call = http.newBuilder().readTimeout(java.time.Duration.ofMinutes(5)).build().newCall(request)
        // Cancelling the collector (the user stops the AI) cancels the HTTP call,
        // so the server stops streaming — and spending — at once.
        val reader = launch(Dispatchers.IO) {
            val response = try {
                call.execute()
            } catch (e: IOException) {
                if (!call.isCanceled()) close(ApiException(0, "network", networkErrorMessage()))
                return@launch
            }
            response.use {
                if (!it.isSuccessful) { close(errorFrom(it)); return@launch }
                try {
                    val source = it.body.source()
                    var event = "message"
                    val data = StringBuilder()
                    while (!source.exhausted()) {
                        val line = source.readUtf8Line() ?: break
                        when {
                            line.startsWith("event:") -> event = line.removePrefix("event:").trim()
                            line.startsWith("data:") -> data.append(line.removePrefix("data:").trimStart())
                            line.isEmpty() -> {
                                if (data.isNotEmpty()) send(SseEvent(event, data.toString()))
                                event = "message"
                                data.clear()
                            }
                        }
                    }
                    close()
                } catch (e: IOException) {
                    if (!call.isCanceled()) close(ApiException(0, "network", networkErrorMessage()))
                }
            }
        }
        awaitClose {
            call.cancel()
            reader.cancel()
        }
    }.flowOn(Dispatchers.IO)

    companion object {
        fun toJson(value: Any?): JsonElement = when (value) {
            null -> kotlinx.serialization.json.JsonNull
            is JsonElement -> value
            is String -> kotlinx.serialization.json.JsonPrimitive(value)
            is Number -> kotlinx.serialization.json.JsonPrimitive(value)
            is Boolean -> kotlinx.serialization.json.JsonPrimitive(value)
            is Map<*, *> -> JsonObject(value.entries.associate { (k, v) -> k.toString() to toJson(v) })
            is Collection<*> -> kotlinx.serialization.json.JsonArray(value.map { toJson(it) })
            else -> kotlinx.serialization.json.JsonPrimitive(value.toString())
        }
    }
}

data class SseEvent(val event: String, val data: String)
