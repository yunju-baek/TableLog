package work.yunju.tablelog.ai

import android.content.Context
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import org.json.JSONObject
import java.io.File

class LocalModelStore(context: Context) {
    private val manifest = JSONObject(context.assets.open("local-models.json").bufferedReader().use { it.readText() })
    val id: String = manifest.getString("id")
    val directory = File(context.filesDir, "ai-models/$id")
    val files: List<ModelFile> = manifest.getJSONArray("files").let { array -> List(array.length()) { i ->
        array.getJSONObject(i).let { ModelFile(it.getString("name"), it.getString("url"), it.getLong("bytes"), it.getString("sha256")) }
    } }
    fun installed() = files.all { File(directory, it.name).let { f -> f.isFile && f.length() == it.bytes } }
    suspend fun verify() {
        for (spec in files) {
            currentCoroutineContext().ensureActive()
            check(ModelDownload.verified(File(directory, spec.name), spec)) { "로컬 모델이 없거나 손상되었습니다. 설정에서 모델을 설치해 주세요." }
        }
    }
    suspend fun install(progress: (Int) -> Unit) {
        directory.mkdirs()
        val remaining = files.sumOf { (it.bytes - File(directory, it.name + ".part").length()).coerceAtLeast(0) }
        check(directory.usableSpace > remaining + 64 * 1024 * 1024) { "모델 설치를 위해 저장 공간을 350MB 이상 확보해 주세요." }
        val downloader = ModelDownload()
        var done = 0L
        val total = files.sumOf { it.bytes }
        for (spec in files) {
            currentCoroutineContext().ensureActive()
            downloader.fetch(spec, File(directory, spec.name)) { progress(((done + it) * 100 / total).toInt()) }
            done += spec.bytes
        }
        verify()
    }
}
