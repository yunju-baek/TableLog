package work.yunju.tablelog.data

import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.UUID

data class Utterance(
    val id: Int,
    val speaker: String = "화자 1",
    val start: Double = 0.0,
    val end: Double = start,
    val text: String,
)

data class Meeting(
    val id: String = UUID.randomUUID().toString(),
    val title: String,
    val startedAt: Long = System.currentTimeMillis(),
    val endedAt: Long? = null,
    val durationSeconds: Double = 0.0,
    val audioName: String? = null,
    val status: String = "saved",
    val utterances: List<Utterance> = emptyList(),
    val minutes: String = "",
    val notes: String = "",
    val deleted: Boolean = false,
    val revision: Int = 0,
)

object MeetingCodec {
    fun encode(m: Meeting): String = JSONObject().apply {
        put("android_schema", 1); put("id", m.id); put("title", m.title)
        put("startedAt", m.startedAt); put("endedAt", m.endedAt)
        put("durationSeconds", m.durationSeconds); put("audioName", m.audioName)
        put("status", m.status); put("minutes", m.minutes); put("notes", m.notes)
        put("deleted", m.deleted); put("revision", m.revision)
        put("utterances", JSONArray(m.utterances.map {
            JSONObject().put("id", it.id).put("speaker", it.speaker)
                .put("start", it.start).put("end", it.end).put("text", it.text)
        }))
    }.toString(2)

    fun decode(text: String): Meeting {
        val j = JSONObject(text)
        require(j.getInt("android_schema") == 1) { "지원하지 않는 저장 형식입니다." }
        val segments = j.getJSONArray("utterances")
        return Meeting(
            id = j.getString("id"), title = j.getString("title"), startedAt = j.getLong("startedAt"),
            endedAt = if (j.has("endedAt")) j.getLong("endedAt") else null,
            durationSeconds = j.getDouble("durationSeconds"),
            audioName = if (j.has("audioName")) j.getString("audioName") else null,
            status = j.getString("status"), minutes = j.optString("minutes"), notes = j.optString("notes"),
            deleted = j.optBoolean("deleted"), revision = j.optInt("revision"),
            utterances = List(segments.length()) { i ->
                val s = segments.getJSONObject(i)
                Utterance(s.getInt("id"), s.getString("speaker"), s.getDouble("start"), s.getDouble("end"), s.getString("text"))
            },
        ).also(::validate)
    }

    fun validate(m: Meeting) {
        UUID.fromString(m.id)
        require(m.title.isNotBlank() && m.title.length <= 500) { "회의 제목을 확인해 주세요." }
        require(m.durationSeconds.isFinite() && m.durationSeconds >= 0) { "잘못된 녹음 길이입니다." }
        require(m.audioName == null || m.audioName == "recording.wav") { "잘못된 오디오 경로입니다." }
        require(m.utterances.map { it.id }.distinct().size == m.utterances.size) { "발언 번호가 중복됩니다." }
        require(m.utterances.all { it.start.isFinite() && it.end.isFinite() && it.start >= 0 && it.end >= it.start }) { "발언 시각을 확인해 주세요." }
    }

    /** Imports a copy. External paths and session IDs never become local file paths. */
    fun importTranscript(text: String): Meeting {
        val j = JSONObject(text)
        if (j.has("android_schema")) return decode(text).copy(
            id = UUID.randomUUID().toString(), audioName = null, status = "imported", deleted = false, revision = 0,
        )
        val segments = j.getJSONArray("segments")
        val names = mutableMapOf<Int, String>()
        j.optJSONArray("speakers")?.let { a -> repeat(a.length()) {
            val s = a.getJSONObject(it)
            if (!s.isNull("name")) names[s.getInt("speaker")] = s.getString("name")
        } }
        val utterances = List(segments.length()) { i ->
            val s = segments.getJSONObject(i)
            val corrected = !s.isNull("corrected_text") && s.optString("correction_status") in setOf("corrected", "unchanged", "accepted")
            val start = s.optDouble("start_time", s.optDouble("start", 0.0))
            val speaker = s.optInt("speaker", 0)
            Utterance(i + 1,
                if (!s.isNull("speaker_name") && s.optString("speaker_name").isNotBlank()) s.getString("speaker_name") else names[speaker] ?: "화자 ${speaker + 1}",
                start, s.optDouble("end_time", s.optDouble("end", start)),
                if (corrected) s.getString("corrected_text") else s.getString("text"))
        }
        return Meeting(
            title = j.optString("title").ifBlank { "가져온 회의" }.take(500),
            startedAt = runCatching { Instant.parse(j.getString("started_at")).toEpochMilli() }.getOrDefault(System.currentTimeMillis()),
            durationSeconds = j.optDouble("duration_seconds", utterances.maxOfOrNull { it.end } ?: 0.0),
            status = "imported", utterances = utterances,
        ).also(::validate)
    }

    /** Core transcript fields understood by the macOS TableLog reader. */
    fun desktopTranscript(m: Meeting): String {
        val speakers = m.utterances.map { it.speaker }.distinct()
        return JSONObject().apply {
            put("schema_version", 15); put("app", "테이블로그 Android")
            put("session_id", m.id); put("title", m.title)
            put("started_at", Instant.ofEpochMilli(m.startedAt).toString())
            m.endedAt?.let { put("ended_at", Instant.ofEpochMilli(it).toString()) }
            put("saved_at", Instant.now().toString()); put("duration_seconds", m.durationSeconds)
            put("source", "android"); put("status", "saved")
            put("text", m.utterances.joinToString("\n") { it.text })
            put("speakers", JSONArray(speakers.mapIndexed { index, name -> JSONObject().put("speaker", index).put("name", name) }))
            put("segments", JSONArray(m.utterances.map {
                JSONObject().put("id", it.id).put("speaker", speakers.indexOf(it.speaker))
                    .put("speaker_name", it.speaker).put("start_time", it.start).put("end_time", it.end).put("text", it.text)
            }))
        }.toString(2)
    }

    fun markdown(m: Meeting): String = buildString {
        appendLine("# ${m.title.replace('\n', ' ')}\n")
        appendLine("${dateLabel(m.startedAt)} · 녹음 ${timeLabel(m.durationSeconds)}\n")
        if (m.minutes.isNotBlank()) { appendLine(m.minutes); appendLine() }
        if (m.notes.isNotBlank()) { appendLine("## 메모\n"); appendLine(m.notes); appendLine() }
        appendLine("## 녹취\n")
        m.utterances.forEach {
            appendLine("### ${timeLabel(it.start)} · ${it.speaker.replace('\n', ' ')}\n")
            appendLine(it.text); appendLine()
        }
    }

    fun minutesTemplate(m: Meeting): String = """
        ## 회의 개요

        - 일시: ${dateLabel(m.startedAt)}
        - 참석자: ${m.utterances.map { it.speaker }.distinct().joinToString(", ").ifBlank { "확인 필요" }}

        ## 핵심 요약


        ## 안건별 논의


        ## 결정 사항


        ## 후속 조치

        | 조치 내용 | 담당 | 기한 |
        | --- | --- | --- |

        ## 확인할 사항

    """.trimIndent()
}

fun timeLabel(seconds: Double): String {
    val n = seconds.coerceAtLeast(0.0).toLong()
    return if (n >= 3600) "%02d:%02d:%02d".format(n / 3600, n / 60 % 60, n % 60) else "%02d:%02d".format(n / 60, n % 60)
}
fun dateLabel(millis: Long): String = DateTimeFormatter.ofPattern("yyyy.MM.dd  HH:mm")
    .withZone(ZoneId.systemDefault()).format(Instant.ofEpochMilli(millis))
