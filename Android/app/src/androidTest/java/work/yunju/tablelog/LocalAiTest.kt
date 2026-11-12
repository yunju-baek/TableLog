package work.yunju.tablelog

import android.content.Context
import android.content.Intent
import android.os.Debug
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.core.content.ContextCompat
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import work.yunju.tablelog.ai.*
import work.yunju.tablelog.data.*
import work.yunju.tablelog.audio.WavFile
import java.io.File

@RunWith(AndroidJUnit4::class)
class LocalAiTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()

    @Test fun installFromPublicSourcesWhenExplicitlyRequested() {
        assumeTrue("Network download is an explicit opt-in test", InstrumentationRegistry.getArguments().getString("downloadModel") == "true")
        val app = compose.activity.application as TableLogApplication
        compose.waitUntil(10_000) { app.ready.value }
        runBlocking(kotlinx.coroutines.Dispatchers.IO) {
            LocalModelStore(app).install {}
            LocalModelStore(app).verify()
        }
    }

    @Test fun modePersistsAndTokenCannotMoveToAnotherEndpoint() {
        val context = compose.activity
        val store = SettingsStore(context)
        store.clear(); store.setSpeechMode(SpeechMode.LOCAL)
        assertEquals(SpeechMode.LOCAL, SettingsStore(context).speechMode())
        val first = AISettings("https://example.com/v1", "speech", "minutes", "synthetic-device-token")
        store.save(first)
        assertEquals(first, store.read())
        assertThrows(IllegalArgumentException::class.java) { store.save(first.copy(baseUrl = "https://other.example/v1")) }
        val prefs = context.getSharedPreferences("ai-settings", Context.MODE_PRIVATE)
        assertFalse(prefs.getString("secret", "")!!.contains(first.apiKey))
        // Ciphertext cannot be transplanted to a different URL in preferences.
        prefs.edit().putString("url", "https://other.example/v1").commit()
        assertThrows(Exception::class.java) { store.read() }
        assertEquals(SpeechMode.LOCAL, store.speechMode()) // Local mode does not need a readable server credential.
        store.clear()
        assertEquals(SpeechMode.LOCAL, store.speechMode())
        compose.activityRule.scenario.recreate()
        assertEquals(SpeechMode.LOCAL, SettingsStore(compose.activity).speechMode())
    }

    /** Opt-in fixture provisioned by scripts/smoke-local.py; never downloads during this test. */
    @Test fun actualKoreanModelTranscribesOfflineAndServicePreservesReview() = runBlocking {
        val app = compose.activity.application as TableLogApplication
        compose.waitUntil(10_000) { app.ready.value }
        val models = LocalModelStore(app)
        val fixture = File(app.filesDir, "verification/ko.wav")
        assumeTrue("Provision the pinned model and public Korean fixture to run this smoke test", models.installed() && fixture.isFile)
        val started = System.nanoTime()
        val output = LocalTranscriber(models).transcribe(fixture) {}
        val elapsed = (System.nanoTime() - started) / 1e9
        val duration = LocalTranscriber.validateWave(fixture)
        assertTrue(output.isNotEmpty())
        assertTrue(output.any { it.text.contains(Regex("[가-힣]")) })
        assertTrue(output.all { it.start >= 0 && it.end <= duration && it.speaker == "화자 미지정" })
        val repeated = File(app.filesDir, "verification/repeated-ko.wav")
        val speech = fixture.readBytes().copyOfRange(44 + 6400, 44 + 134400)
        repeated.outputStream().use { out ->
            out.write(WavFile.header(speech.size.toLong() * 12))
            repeat(12) { out.write(speech) }
        }
        val longOutput = LocalTranscriber(models).transcribe(repeated) {}
        assertTrue(longOutput.size >= 2)
        assertTrue(longOutput.all { it.end - it.start <= 25.0 && it.end <= 48.0 })
        assertTrue(longOutput.zipWithNext().all { (a, b) -> a.start <= b.start })
        val memory = Debug.MemoryInfo().also(Debug::getMemoryInfo)
        File(app.filesDir, "verification/local-smoke.json").writeText(JSONObject()
            .put("runtime", "sherpa-onnx 2.0.1 CPU / 2 threads").put("device", android.os.Build.MODEL)
            .put("audio_seconds", duration).put("wall_seconds", elapsed).put("rtf", elapsed / duration)
            .put("process_pss_after_kib", memory.totalPss).put("text", output.joinToString(" ") { it.text })
            .put("accuracy_benchmark", false).toString(2))

        val original = app.repository.save(Meeting(title = "공개 한국어 샘플 로컬 전사 검증", durationSeconds = duration,
            audioName = "recording.wav", utterances = listOf(Utterance(1, text = "보존할 기존 발언"))))
        fixture.copyTo(app.repository.audioFile(original)!!)
        compose.runOnUiThread {
            ContextCompat.startForegroundService(app, Intent(app, LocalAiService::class.java)
                .setAction(LocalAiService.TRANSCRIBE).putExtra("meetingId", original.id))
        }
        compose.waitUntil(120_000) { LocalAiService.proposalFile(app, original.id).baseFile.isFile }
        val proposal = LocalAiService.readProposal(app, original.id)!!
        assertEquals(original.revision, proposal.revision)
        assertTrue(proposal.utterances.any { it.text.contains(Regex("[가-힣]")) })
        assertEquals("보존할 기존 발언", app.repository.get(original.id)!!.utterances.single().text)
        compose.waitUntil(10_000) { !LocalAiService.state.value.running }
        compose.activityRule.scenario.recreate()
        assertNotNull(LocalAiService.readProposal(app, original.id))
    }
}
