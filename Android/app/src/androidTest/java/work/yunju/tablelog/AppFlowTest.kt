package work.yunju.tablelog

import android.Manifest
import android.content.Intent
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.core.content.ContextCompat
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.rule.GrantPermissionRule
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import work.yunju.tablelog.audio.RecordingService
import work.yunju.tablelog.audio.WavFile
import work.yunju.tablelog.data.*
import java.nio.ByteBuffer
import java.nio.ByteOrder

@RunWith(AndroidJUnit4::class)
class AppFlowTest {
    @get:Rule(order = 0) val permissions = GrantPermissionRule.grant(Manifest.permission.RECORD_AUDIO, Manifest.permission.POST_NOTIFICATIONS)
    @get:Rule(order = 1) val compose = createAndroidComposeRule<MainActivity>()

    @Test fun exampleCanBeEditedArchivedRestoredAndReloaded() {
        val app = compose.activity.application as TableLogApplication
        compose.waitUntil(10_000) { app.ready.value }
        // This fixture is explicitly synthetic; no user recordings are used.
        val fixture = app.repository.save(Meeting(title = "UI 검증 회의 ${java.util.UUID.randomUUID().toString().take(8)}", utterances = listOf(Utterance(1, "가상 화자", text = "검증용 발언"))))
        compose.onNodeWithText(fixture.title).performScrollTo().performClick()
        compose.onNodeWithContentDescription("회의 이름 수정").performClick()
        compose.onNode(hasSetTextAction() and hasText("내용")).performTextReplacement("UI 수정된 회의")
        compose.onNodeWithText("저장", useUnmergedTree = true).performClick()
        compose.waitUntil(5_000) { app.repository.get(fixture.id)?.title == "UI 수정된 회의" }
        compose.onNodeWithContentDescription("발언 1 수정").performScrollTo().performClick()
        compose.onNodeWithText("발언 내용").performTextReplacement("저장 후에도 남는 발언")
        compose.onNodeWithText("저장", useUnmergedTree = true).performClick()
        compose.waitUntil(5_000) { app.repository.get(fixture.id)?.utterances?.single()?.text == "저장 후에도 남는 발언" }
        compose.onNodeWithText("휴지통으로 이동").performScrollTo().performClick()
        compose.onNodeWithText("이동", useUnmergedTree = true).performClick()
        compose.waitUntil(5_000) { app.repository.get(fixture.id)?.deleted == true }
        compose.onNodeWithContentDescription("휴지통").performClick()
        compose.onNodeWithText("복원").performScrollTo().performClick()
        compose.waitUntil(5_000) { app.repository.get(fixture.id)?.deleted == false }
        val reload = MeetingRepository(app).apply { load() }
        assertEquals("저장 후에도 남는 발언", reload.get(fixture.id)!!.utterances.single().text)
        assertTrue(app.repository.directory(fixture.id).resolve("revisions").listFiles()!!.isNotEmpty())
    }

    @Test fun automaticTranscriptionServiceFinishesAndReleasesItsSession() {
        val app = compose.activity.application as TableLogApplication
        compose.waitUntil(10_000) { app.ready.value }
        val models = work.yunju.tablelog.ai.LocalModelStore(app, "sensevoice-int8-v1")
        org.junit.Assume.assumeTrue(models.installed())
        fun send(action: String) = compose.runOnUiThread {
            val intent = Intent(compose.activity, RecordingService::class.java).setAction(action)
                .putExtra("title", "자동 전사 녹음 검증").putExtra("live", true)
                .putExtra("speechMode", "LOCAL").putExtra("modelId", models.id)
            if (action == RecordingService.START) ContextCompat.startForegroundService(compose.activity, intent)
            else compose.activity.startService(intent)
        }
        try {
            send(RecordingService.START)
            compose.waitUntil(30_000) { RecordingService.state.value.processedSeconds > 1.0 || RecordingService.state.value.error != null || RecordingService.state.value.transcriptionError != null }
            assertNull(RecordingService.state.value.error); assertNull(RecordingService.state.value.transcriptionError)
            val id = RecordingService.state.value.meetingId!!
            assertTrue(RecordingService.state.value.live)
            compose.activityRule.scenario.recreate()
            assertEquals(id, RecordingService.state.value.meetingId)
            send(RecordingService.STOP)
            compose.waitUntil(60_000) { !RecordingService.state.value.running }
            assertEquals("complete", app.repository.get(id)!!.transcriptionStatus)
            assertEquals(models.definition.name, app.repository.get(id)!!.transcriptionModel)
            assertNull(RecordingService.state.value.error)
            work.yunju.tablelog.ai.LocalTranscriber.validateWave(app.repository.audioFile(app.repository.get(id)!!)!!)
        } finally { send(RecordingService.STOP); send(RecordingService.CANCEL_TRANSCRIPTION) }
    }

    @Test fun foregroundRecorderPausesResumesSurvivesRecreationAndWritesValidWav() {
        val app = compose.activity.application as TableLogApplication
        compose.waitUntil(10_000) { app.ready.value }
        fun send(action: String) = compose.runOnUiThread {
            val intent = Intent(compose.activity, RecordingService::class.java).setAction(action).putExtra("title", "합성 녹음 검증").putExtra("live", false)
            if (action == RecordingService.START) ContextCompat.startForegroundService(compose.activity, intent)
            else compose.activity.startService(intent)
        }
        try {
            send(RecordingService.START)
            compose.waitUntil(15_000) { RecordingService.state.value.seconds > 1.0 || RecordingService.state.value.error != null }
            assertNull(RecordingService.state.value.error)
            val id = RecordingService.state.value.meetingId!!
            send(RecordingService.PAUSE)
            compose.waitUntil(5_000) { RecordingService.state.value.paused }
            val pausedAt = RecordingService.state.value.seconds
            Thread.sleep(500)
            assertEquals(pausedAt, RecordingService.state.value.seconds, 0.0)
            compose.activityRule.scenario.recreate()
            assertEquals(id, RecordingService.state.value.meetingId)
            send(RecordingService.RESUME)
            compose.waitUntil(5_000) { RecordingService.state.value.seconds > pausedAt + 0.5 }
            app.repository.update(id) { it.copy(notes = "녹음 중 보존할 메모") }
            send(RecordingService.STOP)
            compose.waitUntil(10_000) { RecordingService.state.value.meetingId == null }
            val meeting = app.repository.get(id)!!
            assertEquals("saved", meeting.status)
            assertEquals("녹음 중 보존할 메모", meeting.notes)
            val file = app.repository.audioFile(meeting)!!
            val bytes = file.readBytes()
            assertEquals("RIFF", bytes.take(4).toByteArray().toString(Charsets.US_ASCII))
            assertEquals(bytes.size - 44, ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN).getInt(40))
            assertEquals((bytes.size - 44).toDouble() / WavFile.BYTES_PER_SECOND, meeting.durationSeconds, 0.0)
        } finally { send(RecordingService.STOP) }
    }
}
