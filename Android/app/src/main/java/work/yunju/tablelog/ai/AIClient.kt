package work.yunju.tablelog.ai

import kotlinx.coroutines.suspendCancellableCoroutine
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.RequestBody.Companion.toRequestBody
import okio.BufferedSink
import org.json.JSONArray
import org.json.JSONObject
import work.yunju.tablelog.audio.WavFile
import work.yunju.tablelog.data.*
import java.io.File
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.RandomAccessFile
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/** Optional server contract: /audio/transcriptions and /chat/completions, both under the configured base URL. */
class AIClient(private val settings: AISettings, private val client: OkHttpClient = defaultClient(), private val language: String = "ko") {

    private suspend fun post(path: String, body: RequestBody? = null): String {
        settings.validate()
        val request = Request.Builder().url(settings.canonicalUrl() + path).apply {
            if (body != null) post(body) else get()
            header("Authorization", "Bearer ${settings.apiKey}")
        }.build()
        return suspendCancellableCoroutine { continuation ->
            val call = client.newCall(request)
            continuation.invokeOnCancellation { call.cancel() }
            call.enqueue(object : Callback {
                override fun onFailure(call: Call, e: IOException) {
                    if (continuation.isActive) continuation.resumeWithException(IOException("서버에 연결하지 못했습니다. 주소와 네트워크를 확인해 주세요.", e))
                }
                override fun onResponse(call: Call, response: Response) {
                    val result = runCatching {
                        response.use {
                            check(it.code != 401) { "서버 인증이 만료되었거나 토큰이 잘못되었습니다. 기기 토큰을 다시 등록해 주세요." }
                            check(it.code != 403) { "이 기기에 요청 권한이 없습니다. 서버의 기기 권한을 확인해 주세요." }
                            check(it.isSuccessful) { "서버가 요청을 처리하지 못했습니다. HTTP ${it.code}. 서버 주소와 모델 설정을 확인해 주세요." }
                            val body = it.body ?: error("서버 응답이 비어 있습니다.")
                            val output = ByteArrayOutputStream()
                            val input = body.byteStream()
                            val buffer = ByteArray(8192)
                            while (true) {
                                val n = input.read(buffer); if (n < 0) break
                                check(output.size() + n <= 4 * 1024 * 1024) { "서버 응답이 너무 큽니다." }
                                output.write(buffer, 0, n)
                            }
                            output.toString("UTF-8")
                        }
                    }
                    if (continuation.isActive) result.fold(continuation::resume, continuation::resumeWithException)
                }
            })
        }
    }

    suspend fun checkConnection(): String {
        val data = JSONObject(post("/models")).getJSONArray("data")
        return "HTTPS 연결·모델 목록 응답 확인 (${data.length()}개). 실제 전사 품질은 별도 확인이 필요합니다."
    }

    suspend fun transcribe(file: File, progress: (String) -> Unit): List<Utterance> {
        require(settings.speechModel.isNotBlank()) { "설정에서 음성 모델 이름을 입력해 주세요." }
        val dataSize = file.length() - WavFile.HEADER_SIZE
        require(dataSize > 0) { "녹음 파일이 비어 있습니다." }
        val chunkBytes = 300L * WavFile.BYTES_PER_SECOND
        val chunks = (dataSize + chunkBytes - 1) / chunkBytes
        val result = mutableListOf<Utterance>()
        var offset = 0L
        while (offset < dataSize) {
            progress("음성 전사 ${offset / chunkBytes + 1} / $chunks")
            val size = minOf(chunkBytes, dataSize - offset)
            result += transcribeRange(file, offset, size).map { it.copy(id = result.size + it.id) }
            offset += size
        }
        require(result.isNotEmpty()) { "인식된 발언이 없습니다. 오디오와 서버의 음성 모델을 확인해 주세요." }
        return result
    }

    internal suspend fun transcribeRange(file: File, start: Long, size: Long): List<Utterance> {
        require(start >= 0 && size > 0 && size <= 300L * WavFile.BYTES_PER_SECOND && start + size <= file.length() - WavFile.HEADER_SIZE)
            val audio = object : RequestBody() {
                override fun contentType() = "audio/wav".toMediaType()
                override fun contentLength() = WavFile.HEADER_SIZE + size
                override fun writeTo(sink: BufferedSink) {
                    sink.write(WavFile.header(size))
                    RandomAccessFile(file, "r").use { stream ->
                        stream.seek(WavFile.HEADER_SIZE + start)
                        val buffer = ByteArray(8192)
                        var remaining = size
                        while (remaining > 0) {
                            val n = stream.read(buffer, 0, minOf(remaining, buffer.size.toLong()).toInt())
                            check(n > 0) { "녹음 파일을 끝까지 읽지 못했습니다." }
                            sink.write(buffer, 0, n); remaining -= n
                        }
                    }
                }
            }
            val body = MultipartBody.Builder().setType(MultipartBody.FORM)
                .addFormDataPart("model", settings.speechModel)
                .addFormDataPart("language", language).addFormDataPart("response_format", "verbose_json")
                .addFormDataPart("file", "recording.wav", audio).build()
            val parsed = parseTranscript(post("/audio/transcriptions", body), start.toDouble() / WavFile.BYTES_PER_SECOND, size.toDouble() / WavFile.BYTES_PER_SECOND)
            return parsed
    }

    suspend fun ask(system: String, input: String): String {
        require(settings.textModel.isNotBlank()) { "설정에서 회의 AI 모델을 선택해 주세요." }
        require(input.length + system.length <= 45000) { "회의 AI 입력이 너무 깁니다. 범위를 나누어 주세요." }
        val messages = JSONArray().put(JSONObject().put("role", "system").put("content", system))
            .put(JSONObject().put("role", "user").put("content", input))
        val body = JSONObject().put("model", settings.textModel).put("messages", messages).put("stream", false).put("max_tokens", 2048)
        val response = JSONObject(post("/chat/completions", body.toString().toRequestBody("application/json; charset=utf-8".toMediaType())))
        val text = response.getJSONArray("choices").getJSONObject(0).getJSONObject("message").getString("content").trim()
        require(text.isNotBlank() && text != "null") { "회의 AI 응답이 비어 있습니다." }
        return text
    }

    suspend fun minutes(m: Meeting): String = MeetingAI(this).minutes(m)

    companion object {
        fun defaultClient(): OkHttpClient = OkHttpClient.Builder().followRedirects(false).followSslRedirects(false)
            .connectTimeout(20, TimeUnit.SECONDS).readTimeout(180, TimeUnit.SECONDS).callTimeout(240, TimeUnit.SECONDS).build()
        fun parseTranscript(text: String, offset: Double, duration: Double): List<Utterance> {
            val root = JSONObject(text)
            val segments = root.optJSONArray("segments")
            if (segments == null || segments.length() == 0) {
                val value = root.optString("text").trim()
                return if (value.isBlank()) emptyList() else listOf(Utterance(1, "화자 미지정", offset, offset + duration, value))
            }
            return List(segments.length()) { i ->
                val s = segments.getJSONObject(i)
                val start = s.getDouble("start"); val end = s.getDouble("end")
                require(start.isFinite() && end.isFinite() && start >= 0 && end >= start && end <= duration + 2) { "서버의 발언 시각 형식이 올바르지 않습니다." }
                // No automatic speaker identification is implied by this client.
                Utterance(i + 1, "화자 미지정", offset + start.coerceAtMost(duration), offset + end.coerceAtMost(duration), s.getString("text").trim())
            }.filter { it.text.isNotBlank() }.mapIndexed { index, u -> u.copy(id = index + 1) }
        }
    }
}
