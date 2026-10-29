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
                if (m.status in listOf("recording", "paused", "importing")) {
                    val wav = audioFile(m)
                    val seconds = if (wav?.exists() == true) runCatching { WavFile.repair(wav) }.getOrElse {
                        warning.value = "일부 녹음 파일을 복구하지 못했습니다. 회의 정보와 원본 파일은 보존되어 있습니다."
                        m.durationSeconds
                    } else m.durationSeconds
                    m = m.copy(status = "interrupted", durationSeconds = seconds, endedAt = System.currentTimeMillis(),
                        transcriptionStatus = if (m.transcriptionStatus == "running") "interrupted" else m.transcriptionStatus)
                    write(m)
                }
                if (m.transcriptionStatus == "running") {
                    m = m.copy(transcriptionStatus = "interrupted"); write(m)
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

    fun canUndo(m: Meeting): Boolean = File(directory(m.id), "revisions").listFiles().orEmpty().any { it.name.startsWith("${m.revision - 1}-") }

    @Synchronized fun undo(id: String, expectedRevision: Int): Meeting {
        val current = get(id) ?: error("회의가 없습니다.")
        require(current.revision == expectedRevision && current.status !in listOf("recording", "paused")) { "기록이 변경되었습니다. 현재 내용을 확인해 주세요." }
        val priorFile = File(directory(id), "revisions").listFiles().orEmpty().firstOrNull { it.name.startsWith("${current.revision - 1}-") }
            ?: error("되돌릴 수 있는 직전 편집이 없습니다.")
        val previous = MeetingCodec.decode(priorFile.readText())
        return update(id) { it.copy(title = previous.title, utterances = previous.utterances, minutes = previous.minutes, notes = previous.notes, materials = previous.materials) }
    }

    /** Appends to the latest revision, preserving notes, corrected text and manually added turns. */
    @Synchronized fun appendLive(id: String, utterance: Utterance) = update(id, snapshot = false) { m ->
        check(!m.deleted)
        val next = utterance.copy(id = (m.utterances.maxOfOrNull { it.id } ?: 0) + 1)
        m.copy(utterances = (m.utterances + next).sortedWith(compareBy({ it.start }, { it.id })),
            durationSeconds = maxOf(m.durationSeconds, next.end))
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
