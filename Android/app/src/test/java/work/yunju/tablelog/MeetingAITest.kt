package work.yunju.tablelog

import org.junit.Assert.*
import org.junit.Test
import work.yunju.tablelog.ai.MeetingAI
import work.yunju.tablelog.audio.PcmResampler
import work.yunju.tablelog.data.*

class MeetingAITest {
    @Test fun correctionsCannotChangeIdentityOrTimingOrDropTurns() {
        val original = listOf(Utterance(9, "민서", 2.0, 7.0, "원문"))
        val result = MeetingAI.parseCorrections(original, """[{"id":9,"text":"교정"}]""")
        assertEquals(original.single().copy(text = "교정"), result.single())
        assertThrows(IllegalArgumentException::class.java) { MeetingAI.parseCorrections(original, "[]") }
        assertThrows(IllegalArgumentException::class.java) { MeetingAI.parseCorrections(original, """[{"id":8,"text":"교정"}]""") }
    }
    @Test fun speakerRenameAndSplitPreserveOtherTurnsAndUniqueIds() {
        val m = Meeting(title = "편집", utterances = listOf(Utterance(4,"화자 1",1.0,8.0,"앞 뒤"), Utterance(9,"화자 2",9.0,10.0,"다음")))
        val renamed = TranscriptEdits.renameSpeaker(m,"화자 1","민서")
        val split = TranscriptEdits.split(renamed,4,4.0,"앞","뒤")
        assertEquals(listOf(4,10,9),split.utterances.map { it.id })
        assertEquals(listOf("민서","민서","화자 2"),split.utterances.map { it.speaker })
        assertEquals(m.utterances.last(),split.utterances.last())
        assertThrows(IllegalArgumentException::class.java) { TranscriptEdits.split(m,4,9.0,"앞","뒤") }
    }
    @Test fun longQuestionContextIsBoundedAndDisclosesSelection() {
        val m = Meeting(title="긴 회의",utterances=List(1000) { Utterance(it+1,start=it.toDouble(),text=if(it==999) "특별기한은 금요일입니다" else "반복되는 회의 발언 내용입니다 ".repeat(10)) })
        val (context, notice) = MeetingAI.questionContext(m,"특별기한")
        assertTrue(context.length <= 20000); assertTrue(context.contains("특별기한은 금요일")); assertTrue(notice.contains("1000개"))
    }
    @Test fun resamplingCarriesPositionAndDoesNotAccumulateAudio() {
        for (rate in listOf(8000,16000,44100,48000)) {
            val resampler=PcmResampler(rate); var count=0; var maximum=0
            repeat(rate*2) { resampler.accept(1000) { count++;maximum=maxOf(maximum,it) } }
            assertTrue(kotlin.math.abs(count-32000)<=1); assertEquals(1000,maximum)
        }
    }
    @Test fun newFieldsRoundTripAndLegacyDefaultsRemainReadable() {
        val m=Meeting(title="호환",summary="요약",automaticMinutes="자동 회의록",materials="자료",assistant=listOf(AssistantTurn("질문","답변")))
        assertEquals(m,MeetingCodec.decode(MeetingCodec.encode(m)))
        val json=org.json.JSONObject(MeetingCodec.encode(m));listOf("summary","automaticMinutes","materials","assistant").forEach(json::remove)
        val old=MeetingCodec.decode(json.toString());assertTrue(old.assistant.isEmpty());assertEquals("",old.automaticMinutes)
    }
}
