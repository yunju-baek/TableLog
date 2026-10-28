package work.yunju.tablelog.ai

import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext
import okhttp3.*
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.security.MessageDigest
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

data class ModelFile(val name: String, val url: String, val bytes: Long, val sha256: String)

/** Download only public model files. This client never receives server credentials or meeting data. */
class ModelDownload(private val client: OkHttpClient = OkHttpClient.Builder()
    .followRedirects(true).followSslRedirects(false).readTimeout(30, java.util.concurrent.TimeUnit.SECONDS).build()) {
    companion object {
        fun sha256(file: File): String {
            val digest = MessageDigest.getInstance("SHA-256")
            file.inputStream().use { input ->
                val buffer = ByteArray(64 * 1024)
                while (true) { val n = input.read(buffer); if (n < 0) break; digest.update(buffer, 0, n) }
            }
            return digest.digest().joinToString("") { "%02x".format(it) }
        }
        fun verified(file: File, spec: ModelFile) = file.isFile && file.length() == spec.bytes && sha256(file) == spec.sha256
    }

    suspend fun fetch(spec: ModelFile, target: File, progress: (Long) -> Unit) {
        require(spec.name == target.name && !spec.name.contains('/') && !spec.name.contains('\\'))
        require(spec.url.startsWith("https://")) { "모델은 HTTPS로만 설치할 수 있습니다." }
        if (verified(target, spec)) { progress(spec.bytes); return }
        target.parentFile!!.mkdirs()
        val part = File(target.parentFile, target.name + ".part")
        if (part.length() > spec.bytes) part.delete()
        if (part.length() == spec.bytes) {
            if (verified(part, spec)) { check(part.renameTo(target)); progress(spec.bytes); return }
            part.delete()
        }
        val offset = part.length()
        val settled = CompletableDeferred<Unit>()
        try { suspendCancellableCoroutine<Unit> { continuation ->
            val request = Request.Builder().url(spec.url).apply {
                if (offset > 0) header("Range", "bytes=$offset-")
                header("Accept-Encoding", "identity")
            }.build()
            val call = client.newCall(request)
            continuation.invokeOnCancellation { call.cancel() }
            call.enqueue(object : Callback {
                override fun onFailure(call: Call, e: IOException) {
                    settled.complete(Unit)
                    if (continuation.isActive) continuation.resumeWithException(IOException("모델 다운로드에 실패했습니다. 다시 누르면 이어받습니다.", e))
                }
                override fun onResponse(call: Call, response: Response) {
                    val result = runCatching {
                        response.use { r ->
                            check(r.isSuccessful && r.request.url.isHttps) { "모델 서버 응답 오류: HTTP ${r.code}" }
                            val resumed = r.code == 206
                            if (resumed) check(r.header("Content-Range") == "bytes $offset-${spec.bytes - 1}/${spec.bytes}") { "모델 이어받기 범위가 올바르지 않습니다." }
                            else check(r.code == 200) { "지원하지 않는 모델 응답입니다." }
                            var count = if (resumed) offset else 0L
                            val body = r.body ?: error("모델 응답이 비어 있습니다.")
                            FileOutputStream(part, resumed).use { out ->
                                body.byteStream().use { input ->
                                    val buffer = ByteArray(64 * 1024)
                                    while (true) {
                                        if (!continuation.isActive) throw IOException("설치 취소")
                                        val n = input.read(buffer); if (n < 0) break
                                        count += n
                                        check(count <= spec.bytes) { "모델 파일이 예상 크기를 초과했습니다." }
                                        out.write(buffer, 0, n); progress(count)
                                    }
                                }
                                out.fd.sync()
                            }
                            check(count == spec.bytes) { "모델 다운로드가 중단되었습니다. 다시 누르면 이어받습니다." }
                            if (!verified(part, spec)) { part.delete(); error("모델 무결성 검사에 실패했습니다. 다시 설치해 주세요.") }
                            if (!continuation.isActive) throw IOException("설치 취소")
                            check(part.renameTo(target)) { "모델을 저장하지 못했습니다." }
                        }
                    }
                    settled.complete(Unit)
                    if (continuation.isActive) result.fold({ continuation.resume(Unit) }, continuation::resumeWithException)
                }
            })
        } } finally { withContext(NonCancellable) { settled.await() } }
    }
}
