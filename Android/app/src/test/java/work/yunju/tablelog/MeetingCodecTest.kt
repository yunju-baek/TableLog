package work.yunju.tablelog

import org.junit.Assert.*
import org.junit.Test
import work.yunju.tablelog.data.*
import work.yunju.tablelog.audio.WavFile
import work.yunju.tablelog.ai.AIClient
import work.yunju.tablelog.ai.AISettings
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

class MeetingCodecTest {
    @Test fun desktopImportUsesAcceptedCorrectionAndPreservesTimes() {
        val imported = MeetingCodec.importTranscript("""{
          "session_id":"../../outside", "title":"주간 회의", "started_at":"2026-10-28T01:00:00Z",
          "duration_seconds":120, "speakers":[{"speaker":3,"name":"김민서"}],
          "audio_file":{"path":"/private/recording.wav"},
          "segments":[
            {"id":10,"speaker":3,"start_time":2.5,"end_time":8,"text":"원문","corrected_text":"교정문","correction_status":"accepted"},
            {"id":11,"speaker":3,"start_time":9,"end_time":10,"text":"유지","corrected_text":"제안","correction_status":"pending"}
          ]
        }""")
        assertEquals("교정문", imported.utterances[0].text)
        assertEquals("유지", imported.utterances[1].text)
        assertEquals("김민서", imported.utterances[0].speaker)
        assertEquals(2.5, imported.utterances[0].start, 0.0)
        assertNull(imported.audioName)
        assertFalse(imported.id.contains('/'))
    }
    @Test fun androidAndDesktopRoundTripKeepKoreanAndTimes() {
        val source = Meeting(title = "회의 🔊", durationSeconds = 4.2, notes = "자료\n검토", minutes = "## 결정 사항\n\n확인 필요",
            utterances = listOf(Utterance(1, "백윤주", 1.2, 4.2, "목요일에 진행하겠습니다.")))
        assertEquals(source, MeetingCodec.decode(MeetingCodec.encode(source)))
        val desktop = MeetingCodec.importTranscript(MeetingCodec.desktopTranscript(source))
        assertEquals(source.utterances, desktop.utterances)
        assertEquals(source.durationSeconds, desktop.durationSeconds, 0.0)
    }
    @Test fun invalidTimeAndDuplicateIDsAreRejected() {
        val negative = Meeting(title = "회의", utterances = listOf(Utterance(1, start = -1.0, text = "발언")))
        assertThrows(IllegalArgumentException::class.java) { MeetingCodec.validate(negative) }
        val duplicate = Meeting(title = "회의", utterances = listOf(Utterance(1, text = "가"), Utterance(1, text = "나")))
        assertThrows(IllegalArgumentException::class.java) { MeetingCodec.validate(duplicate) }
        assertThrows(IllegalArgumentException::class.java) { MeetingCodec.validate(Meeting(title = "회의", audioName = "../../secret")) }
    }
    @Test fun interruptedWavIsRepairedFromActualAudioBytes() {
        val file = File.createTempFile("tablelog-test", ".wav")
        try {
            file.writeBytes(WavFile.header(0) + ByteArray(WavFile.BYTES_PER_SECOND * 2) + byteArrayOf(0))
            assertEquals(2.0, WavFile.repair(file), 0.0)
            val header = ByteBuffer.wrap(file.readBytes().take(44).toByteArray()).order(ByteOrder.LITTLE_ENDIAN)
            assertEquals(64000, header.getInt(40))
            assertEquals(64044L, file.length())
        } finally { file.delete() }
    }
    @Test fun transcriptChunksHaveGlobalTimesAndNoInventedSpeakers() {
        val result = AIClient.parseTranscript("""{"segments":[{"start":1,"end":4,"text":" 발언 "}]}""", 300.0, 10.0)
        assertEquals(301.0, result.single().start, 0.0)
        assertEquals("화자 미지정", result.single().speaker)
        assertThrows(IllegalArgumentException::class.java) {
            AIClient.parseTranscript("""{"segments":[{"start":4,"end":2,"text":"bad"}]}""", 0.0, 10.0)
        }
    }
    @Test fun remoteSettingsRequireHttpsWithoutEmbeddedCredentials() {
        for (url in listOf("http://example.com/v1", "https://user:pass@example.com/v1", "https://example.com/v1?key=x")) {
            assertThrows(IllegalArgumentException::class.java) { AISettings(baseUrl = url).validate() }
        }
        AISettings(baseUrl = "https://example.com/v1").validate()
    }
}
