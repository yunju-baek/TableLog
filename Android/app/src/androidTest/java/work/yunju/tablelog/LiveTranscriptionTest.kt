package work.yunju.tablelog

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.*
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import work.yunju.tablelog.ai.*
import work.yunju.tablelog.audio.WavFile
import work.yunju.tablelog.data.*
import java.io.File
import java.io.RandomAccessFile
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

class LiveTranscriptionTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()

    @Test fun catalogSelectionAndLegacyFolderSurviveRecreation() {
        val app = compose.activity.application as TableLogApplication
        val old = LocalModelStore(app)
        try {
            assertEquals(5, old.catalog.size)
            assertEquals("sensevoice-int8-v1", old.catalog.first().id)
            for (definition in old.catalog) {
                val selected = LocalModelStore(app, definition.id)
                selected.select()
                assertEquals(definition.id, LocalModelStore(app).id)
                assertEquals(File(app.filesDir, "ai-models/${definition.id}"), selected.directory)
                assertTrue(definition.bytes > 100_000_000)
            }
            old.selectLanguage("en")
            assertEquals("en", LocalModelStore(app).language)
            assertThrows(IllegalStateException::class.java) { LocalModelStore(app, "../../meetings") }
        } finally { old.select(); old.selectLanguage(old.language) }
    }

    @Test fun modelMenuSwitchesAndPersistsAndDeletionIsScoped() {
        val app = compose.activity.application as TableLogApplication
        compose.waitUntil(10_000) { app.ready.value }
        val original = LocalModelStore(app)
        try {
            compose.onNodeWithContentDescription("설정").performClick()
            compose.onNodeWithText("${original.definition.name} · ${original.definition.sizeLabel} ▾").performScrollTo().performClick()
            compose.onNodeWithText("Whisper Small INT8").performClick()
            compose.onNodeWithText("Whisper Small INT8 · 376 MB ▾").assertExists()
            compose.onNodeWithText("영어", substring = false).performClick()
            assertEquals("en", LocalModelStore(app).language)
            compose.activityRule.scenario.recreate()
            assertEquals("whisper-small-int8-v1", LocalModelStore(app).id)
        } finally { original.select(); original.selectLanguage(original.language) }
        val root = File(app.cacheDir, "model-delete-${java.util.UUID.randomUUID()}").apply { mkdirs() }
        val context = object : android.content.ContextWrapper(app) { override fun getFilesDir() = root }
        try {
            val target = LocalModelStore(context, "whisper-tiny-int8-v1")
            val other = LocalModelStore(context, "sensevoice-int8-v1")
            target.directory.mkdirs(); File(target.directory, "partial.part").writeText("partial")
            other.directory.mkdirs(); val retained = File(other.directory, "retained").apply { writeText("model") }
            val meeting = File(root, "meeting.json").apply { writeText("keep") }
            target.delete()
            assertFalse(target.directory.exists()); assertEquals("model", retained.readText()); assertEquals("keep", meeting.readText())
        } finally { root.deleteRecursively() }
    }

    /** Opt-in real native-engine test; provision only public fixtures, never personal recordings. */
    @Test fun selectedModelProducesLiveKoreanBeforeStopAndFlushesAfterStop() = runBlocking(Dispatchers.IO) {
        val id = InstrumentationRegistry.getArguments().getString("catalogModel")
        assumeTrue("Explicit model smoke test", id != null)
        val app = compose.activity.application as TableLogApplication
        compose.waitUntil(10_000) { app.ready.value }
        val models = LocalModelStore(app, id)
        assertTrue("Provision ${models.id}", models.installed())
        val ko = File(app.filesDir, "verification/ko.wav")
        assertTrue(ko.isFile)
        val pcm = ko.readBytes().copyOfRange(44, ko.length().toInt())
        val meeting = app.repository.save(Meeting(title = "공개 샘플 자동 전사 ${models.id}", audioName = "recording.wav"))
        val file = app.repository.audioFile(meeting)!!
        val available = AtomicLong(0)
        val done = AtomicBoolean(false)
        val first = CompletableDeferred<Unit>()
        val started = System.nanoTime()
        val output = mutableListOf<Utterance>()
        RandomAccessFile(file, "rw").use { writer ->
            writer.write(WavFile.header(0))
            val job = async {
                LocalTranscriber(models).follow(file, available::get, done::get, { u ->
                    output += u; app.repository.appendLive(meeting.id, u); first.complete(Unit)
                }, {})
            }
            try {
                writer.write(pcm); writer.write(ByteArray(WavFile.BYTES_PER_SECOND))
                available.set(writer.length() - 44)
                withTimeout(240_000) { first.await() }
                assertFalse("Must transcribe before stop", done.get())
                val firstMeeting = app.repository.get(meeting.id)!!
                assertTrue(firstMeeting.utterances.any { it.text.contains(Regex("[가-힣]")) })
                app.repository.update(meeting.id) { it.copy(notes = "보존할 회의 메모", utterances = it.utterances.mapIndexed { index, u -> if (index == 0) u.copy(text = "사용자가 교정한 발언") else u }) }
                writer.write(pcm); available.set(writer.length() - 44)
                done.set(true)
                withTimeout(240_000) { job.await() }
                val saved = app.repository.get(meeting.id)!!
                assertTrue(saved.utterances.size >= 2)
                assertEquals("보존할 회의 메모", saved.notes)
                assertEquals("사용자가 교정한 발언", saved.utterances.first().text)
                assertEquals(saved.utterances.size, saved.utterances.map { it.id }.distinct().size)
                assertTrue(output.all { it.start >= 0 && it.end <= available.get().toDouble() / WavFile.BYTES_PER_SECOND })
                writer.seek(0); writer.write(WavFile.header(available.get()))
                val en = File(app.filesDir, "verification/en.wav")
                assertTrue(en.isFile)
                val english = LocalTranscriber(models).transcribe(en) {}
                assertTrue("English model output", english.any { it.text.contains(Regex("[a-zA-Z]{3}")) })
                val result = JSONObject().put("model", models.id).put("live_before_stop", true).put("stop_flush", true)
                    .put("korean", output.joinToString(" ") { it.text }).put("english", english.joinToString(" ") { it.text })
                    .put("elapsed_seconds", (System.nanoTime() - started) / 1e9).put("accuracy_benchmark", false)
                File(app.filesDir, "verification/${models.id}-live.json").writeText(result.toString(2))
            } finally { done.set(true); job.cancelAndJoin() }
        }
    }
}
