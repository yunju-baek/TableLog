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
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()
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
        assertTrue(AIClient(settings).checkConnection().contains("1개"))
        val sample = File(app.filesDir,"verification/ko.wav")
        assertTrue(sample.isFile)
        val result = AIClient(settings).transcribe(sample) {}
        assertTrue(result.any { it.text.contains(Regex("[가-힣]")) })
        val prefs = app.getSharedPreferences("ai-settings",android.content.Context.MODE_PRIVATE)
        assertFalse(prefs.getString("secret","")!!.contains(settings.apiKey))
    }
}
