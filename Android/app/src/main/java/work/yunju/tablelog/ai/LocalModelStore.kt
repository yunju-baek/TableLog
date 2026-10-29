package work.yunju.tablelog.ai

import android.content.Context
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import org.json.JSONObject
import java.io.File
import java.util.Locale

data class LocalModelDefinition(
    val id: String, val name: String, val engine: String, val description: String, val source: String,
    val tokens: String, val model: String, val encoder: String, val decoder: String, val files: List<ModelFile>,
) {
    val bytes get() = files.sumOf { it.bytes }
    val sizeLabel get() = String.format(Locale.ROOT, "%.0f MB", bytes / 1_000_000.0)
}

/** An immutable model snapshot: changing the preference never changes an in-flight job. */
class LocalModelStore(context: Context, modelId: String? = null) {
    private val prefs = context.getSharedPreferences("local-ai", Context.MODE_PRIVATE)
    val language: String = prefs.getString("language", "auto").takeIf { it in setOf("auto", "ko", "en") } ?: "auto"
    fun selectLanguage(value: String) { require(value in setOf("auto", "ko", "en")); check(prefs.edit().putString("language", value).commit()) }
    val catalog: List<LocalModelDefinition>
    val definition: LocalModelDefinition
    val id get() = definition.id
    val directory: File
    val files get() = definition.files
    init {
        val root = JSONObject(context.assets.open("local-models.json").bufferedReader().use { it.readText() })
        val array = root.getJSONArray("models")
        catalog = List(array.length()) { i ->
            val m = array.getJSONObject(i)
            val entries = m.getJSONArray("files")
            LocalModelDefinition(m.getString("id"), m.getString("name"), m.getString("engine"), m.getString("description"), m.getString("source"),
                m.getString("tokens"), m.optString("model"), m.optString("encoder"), m.optString("decoder"),
                List(entries.length()) { n -> entries.getJSONObject(n).let { ModelFile(it.getString("name"), it.getString("url"), it.getLong("bytes"), it.getString("sha256")) } }
            ).also { spec ->
                require(spec.id.matches(Regex("[a-z0-9-]+")))
                require(spec.files.all { it.name.matches(Regex("[a-zA-Z0-9._-]+")) && !it.name.startsWith(".") })
                require(spec.engine in setOf("sensevoice", "whisper"))
                val needed = listOf(spec.tokens, "silero_vad.onnx") + if (spec.engine == "whisper") listOf(spec.encoder, spec.decoder) else listOf(spec.model)
                require(needed.all { name -> spec.files.any { it.name == name } })
            }
        }
        val selected = modelId ?: prefs.getString("model", root.getString("default"))
        definition = catalog.find { it.id == selected } ?: if (modelId == null) catalog.first { it.id == root.getString("default") } else error("알 수 없는 음성 모델입니다.")
        directory = File(context.filesDir, "ai-models/$id")
    }
    fun select() { check(prefs.edit().putString("model", id).commit()) { "모델 선택을 저장하지 못했습니다." } }
    fun installed() = files.all { File(directory, it.name).let { f -> f.isFile && f.length() == it.bytes } }
    fun hasFiles() = directory.exists()
    fun delete() { check(!directory.exists() || directory.deleteRecursively()) { "모델 파일을 삭제하지 못했습니다." } }
    suspend fun verify() {
        for (spec in files) {
            currentCoroutineContext().ensureActive()
            check(ModelDownload.verified(File(directory, spec.name), spec)) { "${definition.name} 모델이 없거나 손상되었습니다. 설정에서 설치·복구해 주세요." }
        }
    }
    suspend fun install(progress: (Int) -> Unit) {
        directory.mkdirs()
        val remaining = files.sumOf { spec ->
            if (ModelDownload.verified(File(directory, spec.name), spec)) 0L
            else (spec.bytes - File(directory, spec.name + ".part").length()).coerceAtLeast(0)
        }
        check(directory.usableSpace > remaining + 64 * 1024 * 1024) { "설치에 필요한 저장 공간을 ${remaining / 1_000_000 + 68}MB 이상 확보해 주세요." }
        val downloader = ModelDownload()
        var done = 0L
        for (spec in files) {
            currentCoroutineContext().ensureActive()
            downloader.fetch(spec, File(directory, spec.name)) { progress(((done + it) * 100 / definition.bytes).toInt()) }
            done += spec.bytes
        }
        verify()
    }
}
