package work.yunju.tablelog.data

import android.content.Context
import android.util.AtomicFile
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import work.yunju.tablelog.audio.WavFile
import java.io.File
import java.util.UUID

class MeetingRepository(context: Context) {
    private val root = File(context.filesDir, "meetings").apply { mkdirs() }
    private val mutableMeetings = MutableStateFlow<List<Meeting>>(emptyList())
    val meetings = mutableMeetings.asStateFlow()
    val warning = MutableStateFlow<String?>(null)

    @Synchronized fun load() {
        val errors = mutableListOf<String>()
        val records = root.listFiles().orEmpty().filter { it.isDirectory }.mapNotNull { dir ->
            runCatching {
                val file = AtomicFile(File(dir, "meeting.json"))
                var m = MeetingCodec.decode(file.openRead().bufferedReader().use { it.readText() })
                require(dir.name == m.id)
                if (m.status == "recording" || m.status == "paused") {
                    val wav = audioFile(m)
                    val seconds = if (wav?.exists() == true) runCatching { WavFile.repair(wav) }.getOrElse {
                        warning.value = "일부 녹음 파일을 복구하지 못했습니다. 회의 정보와 원본 파일은 보존되어 있습니다."
                        m.durationSeconds
                    } else m.durationSeconds
                    m = m.copy(status = "interrupted", durationSeconds = seconds, endedAt = System.currentTimeMillis())
                    write(m)
                }
                m
            }.getOrElse { errors += dir.name; null }
        }
        mutableMeetings.value = records.sortedByDescending { it.startedAt }
        if (errors.isNotEmpty()) warning.value = "${errors.size}개 회의를 읽지 못했습니다. 원본 파일은 보존되어 있습니다."
    }

    fun directory(id: String): File {
        UUID.fromString(id)
        return File(root, id).apply { mkdirs() }
    }
    fun audioFile(m: Meeting): File? = m.audioName?.let {
        require(it == "recording.wav")
        File(directory(m.id), it)
    }
    @Synchronized fun get(id: String): Meeting? = mutableMeetings.value.find { it.id == id }

    @Synchronized fun save(m: Meeting, snapshot: Boolean = false): Meeting {
        MeetingCodec.validate(m)
        val old = get(m.id)
        val result = m.copy(revision = (old?.revision ?: -1) + 1)
        if (snapshot && old != null) {
            val revisions = File(directory(m.id), "revisions").apply { mkdirs() }
            File(revisions, "${old.revision}-${System.currentTimeMillis()}.json").writeText(MeetingCodec.encode(old))
        }
        write(result)
        mutableMeetings.value = (mutableMeetings.value.filterNot { it.id == m.id } + result).sortedByDescending { it.startedAt }
        return result
    }

    @Synchronized fun update(id: String, snapshot: Boolean = true, edit: (Meeting) -> Meeting): Meeting {
        val current = get(id) ?: error("회의를 찾을 수 없습니다.")
        return save(edit(current), snapshot)
    }

    private fun write(m: Meeting) {
        val file = AtomicFile(File(directory(m.id), "meeting.json"))
        val stream = file.startWrite()
        try {
            stream.write(MeetingCodec.encode(m).toByteArray(Charsets.UTF_8))
            file.finishWrite(stream)
        } catch (e: Exception) { file.failWrite(stream); throw e }
    }

    @Synchronized fun import(text: String): Meeting {
        val m = MeetingCodec.importTranscript(text)
        // Preserve the entire source, including desktop-only fields.
        File(directory(m.id), "import-original.json").writeText(text)
        return save(m)
    }
}
