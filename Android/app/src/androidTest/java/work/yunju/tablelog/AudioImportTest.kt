package work.yunju.tablelog

import android.net.Uri
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import work.yunju.tablelog.audio.*
import work.yunju.tablelog.ai.LocalTranscriber
import work.yunju.tablelog.data.*
import java.io.File

class AudioImportTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()
    @Test fun aacM4aExportAndImportProducePlayableCanonicalAudio() = runBlocking(Dispatchers.IO) {
        val app=compose.activity.application as TableLogApplication
        val source=File(app.filesDir,"verification/ko.wav");assumeTrue(source.isFile)
        val m4a=File(app.cacheDir,"public-sample-export.m4a")
        val wav=File(app.cacheDir,"public-sample-import.wav")
        try {
            AudioExporter.m4a(app,source,Uri.fromFile(m4a)) {}
            assertTrue(m4a.length()>1000);assertTrue(m4a.length()<source.length())
            val duration=AudioImporter.decode(app,Uri.fromFile(m4a),wav) {}
            assertEquals(LocalTranscriber.validateWave(source),duration,0.2)
            assertEquals(duration,LocalTranscriber.validateWave(wav),0.0)
        } finally { m4a.delete();wav.delete() }
    }
    @Test fun undoRefusesStaleRevisionAndPreservesAudioMetadata() {
        val app=compose.activity.application as TableLogApplication
        compose.waitUntil(10_000) { app.ready.value }
        val saved=app.repository.save(Meeting(title="되돌리기 검증",audioName="recording.wav",durationSeconds=20.0,utterances=listOf(Utterance(1,text="원문"))))
        val edited=app.repository.update(saved.id) { it.copy(utterances=listOf(Utterance(1,text="편집"))) }
        assertThrows(IllegalArgumentException::class.java) { app.repository.undo(saved.id,saved.revision) }
        val restored=app.repository.undo(saved.id,edited.revision)
        assertEquals("원문",restored.utterances.single().text);assertEquals(20.0,restored.durationSeconds,0.0);assertEquals("recording.wav",restored.audioName)
    }
}
