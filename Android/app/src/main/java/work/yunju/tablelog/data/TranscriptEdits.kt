package work.yunju.tablelog.data

object TranscriptEdits {
    fun renameSpeaker(m: Meeting, old: String, name: String): Meeting {
        require(name.isNotBlank() && name.length <= 100)
        return m.copy(utterances = m.utterances.map { if (it.speaker == old) it.copy(speaker = name.trim()) else it })
    }
    fun split(m: Meeting, id: Int, at: Double, first: String, second: String): Meeting {
        val u = m.utterances.first { it.id == id }
        require(first.isNotBlank() && second.isNotBlank() && at.isFinite() && at > u.start && at < u.end) { "분리 시각을 발언의 시작과 끝 사이로 지정해 주세요." }
        val nextId = (m.utterances.maxOfOrNull { it.id } ?: 0) + 1
        return m.copy(utterances = m.utterances.flatMap {
            if (it.id == id) listOf(it.copy(end = at, text = first.trim()), it.copy(id = nextId, start = at, text = second.trim())) else listOf(it)
        })
    }
}
