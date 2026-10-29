package work.yunju.tablelog

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import work.yunju.tablelog.ai.*
import java.io.File

class MacServerTest {
    @get:Rule(order = 0) val permissions = androidx.test.rule.GrantPermissionRule.grant(android.Manifest.permission.RECORD_AUDIO, android.Manifest.permission.POST_NOTIFICATIONS)
    @get:Rule(order = 1) val compose = createAndroidComposeRule<MainActivity>()
    @Test fun macPresetAndLiveTranscription() = runBlocking {
        val code = InstrumentationRegistry.getArguments().getString("macCode")
        assumeTrue("Live Mac test requires a one-use code", !code.isNullOrBlank())
        val app = compose.activity.application as TableLogApplication
        compose.waitUntil(10_000) { app.ready.value }
        compose.onNodeWithContentDescription("설정").performClick()
        compose.onNodeWithText("맥스튜디오 선택").performScrollTo().performClick()
        compose.onNodeWithText("맥에서 발급한 일회용 연결 코드").performScrollTo().performTextInput(code!!)
        compose.onNodeWithText("코드로 연결·저장").performScrollTo().performClick()
        compose.waitUntil(30_000) { runCatching { SettingsStore(app).read().speechModel == ServerPairing.MAC_STUDIO_MODEL }.getOrDefault(false) }
        val settings = SettingsStore(app).read()
        assertEquals(SpeechMode.SERVER,SettingsStore(app).speechMode())
        assertTrue(AIClient(settings).checkConnection().contains("2개"))
        val sample = File(app.filesDir,"verification/ko.wav")
        assertTrue(sample.isFile)
        val result = AIClient(settings).transcribe(sample) {}
        assertTrue(result.any { it.text.contains(Regex("[가-힣]")) })
        assertEquals(ServerPairing.MAC_STUDIO_TEXT_MODEL,settings.textModel)
        val fixture = work.yunju.tablelog.data.Meeting(title="공개 합성 회의 AI 검증",utterances=listOf(
            work.yunju.tablelog.data.Utterance(1,"민서",0.0,0.5,"발표 자료는 제가 수요일까지 공유하겠습니다."),
            work.yunju.tablelog.data.Utterance(2,"도윤",0.5,1.0,"회의는 목요일 오후 세 시에 합시다."),
            work.yunju.tablelog.data.Utterance(3,"민서",1.0,1.2,"좋습니다. 예산은 아직 결정하지 않았습니다.")))
        val ai=MeetingAI(AIClient(settings))
        assertTrue(ai.question(fixture,"누가 언제까지 발표 자료를 공유하나요?").contains("민서"))
        assertEquals(fixture.utterances.map { it.id },ai.correct(fixture,"띄어쓰기만 교정").map { it.id })
        // Real foreground recorder: automatic minutes after stop, without a proposal/apply gate.
        fun send(action:String)=compose.runOnUiThread {
            val intent=android.content.Intent(app,work.yunju.tablelog.audio.RecordingService::class.java).setAction(action)
                .putExtra("title","자동 회의록 합성 검증").putExtra("live",true).putExtra("speechMode","LOCAL")
                .putExtra("modelId","sensevoice-int8-v1").putExtra("autoMinutes",true).putExtra("approvedTextServer",settings.canonicalUrl())
            if(action==work.yunju.tablelog.audio.RecordingService.START) androidx.core.content.ContextCompat.startForegroundService(app,intent) else app.startService(intent)
        }
        try {
            send(work.yunju.tablelog.audio.RecordingService.START)
            compose.waitUntil(30_000) { work.yunju.tablelog.audio.RecordingService.state.value.seconds>1.3 || work.yunju.tablelog.audio.RecordingService.state.value.error!=null }
            assertNull(work.yunju.tablelog.audio.RecordingService.state.value.error)
            val id=work.yunju.tablelog.audio.RecordingService.state.value.meetingId!!
            app.repository.update(id) { it.copy(utterances=fixture.utterances,minutes="사용자가 직접 쓴 회의록") }
            send(work.yunju.tablelog.audio.RecordingService.STOP)
            compose.waitUntil(180_000) { !work.yunju.tablelog.audio.RecordingService.state.value.running }
            val saved=app.repository.get(id)!!
            assertTrue(saved.automaticMinutes.contains("민서"))
            assertEquals("사용자가 직접 쓴 회의록",saved.minutes)
            assertNull(work.yunju.tablelog.audio.RecordingService.state.value.error)
        } finally { send(work.yunju.tablelog.audio.RecordingService.STOP);send(work.yunju.tablelog.audio.RecordingService.CANCEL_TRANSCRIPTION) }
        val prefs = app.getSharedPreferences("ai-settings",android.content.Context.MODE_PRIVATE)
        assertFalse(prefs.getString("secret","")!!.contains(settings.apiKey))
    }
}
