package work.yunju.tablelog.ai

import kotlinx.coroutines.suspendCancellableCoroutine
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.io.IOException
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/** A locally issued, one-use code bootstraps an individually revocable device token. */
class ServerPairing(private val client: OkHttpClient = AIClient.defaultClient()) {
    suspend fun connect(baseUrl: String, code: String): AISettings {
        val address = AISettings(baseUrl, apiKey = "validation-only")
        address.validate()
        val normalized = code.trim().replace("-", "").replace(" ", "").uppercase()
        require(normalized.matches(Regex("[A-Z2-9]{12}"))) { "맥에서 발급한 12자리 연결 코드를 입력해 주세요." }
        val request = Request.Builder().url(address.canonicalUrl() + "/devices/connect")
            .post(JSONObject().put("code", normalized).toString().toRequestBody("application/json".toMediaType())).build()
        return suspendCancellableCoroutine { continuation ->
            val call = client.newCall(request)
            continuation.invokeOnCancellation { call.cancel() }
            call.enqueue(object : Callback {
                override fun onFailure(call: Call, e: IOException) {
                    if (continuation.isActive) continuation.resumeWithException(IOException("맥 서버에 연결하지 못했습니다. 주소와 네트워크를 확인해 주세요."))
                }
                override fun onResponse(call: Call, response: Response) {
                    val result = runCatching {
                        response.use {
                            check(it.code != 401) { "연결 코드가 만료되었거나 이미 사용됐습니다. 맥에서 새 코드를 발급해 주세요." }
                            check(it.code != 429) { "연결 시도가 많습니다. 1분 뒤 다시 시도해 주세요." }
                            check(it.isSuccessful) { "서버 연결 실패 (HTTP ${it.code})" }
                            val source = it.body?.source() ?: error("서버 응답이 비어 있습니다.")
                            check(!source.request(16_385)) { "서버 응답이 너무 큽니다." }
                            val json = JSONObject(source.readUtf8())
                            AISettings(address.canonicalUrl(), json.getString("speech_model"), json.optString("text_model"), json.getString("access_token")).also { value ->
                                value.validate()
                                require(value.apiKey.length in 32..128) { "기기 토큰 형식이 올바르지 않습니다." }
                            }
                        }
                    }
                    if (continuation.isActive) result.fold(continuation::resume, continuation::resumeWithException)
                }
            })
        }
    }
    companion object {
        const val MAC_STUDIO_URL = "https://yunju.work/tablelog-api/v1"
        const val MAC_STUDIO_TEXT_MODEL = "tablelog-qwen3.5-4b"
        const val MAC_STUDIO_MODEL = "whisper-large-v3-turbo"
    }
}
