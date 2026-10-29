package work.yunju.fishaudio

import android.view.View
import android.view.ViewGroup
import android.view.MotionEvent
import android.webkit.WebView
import androidx.test.core.app.ActivityScenario
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.json.JSONArray

class WebClientTest {
    private val instrument get() = InstrumentationRegistry.getInstrumentation()
    private fun findWeb(view: View): WebView? = if (view is WebView) view else if (view is ViewGroup) (0 until view.childCount).firstNotNullOfOrNull { findWeb(view.getChildAt(it)) } else null
    private fun js(web: WebView, script: String): String {
        val latch = CountDownLatch(1); var result = ""
        instrument.runOnMainSync { web.evaluateJavascript(script) { result = it; latch.countDown() } }
        assertTrue(latch.await(10,TimeUnit.SECONDS)); return result
    }
    private fun waitFor(web: WebView, script: String, seconds: Int = 30) {
        val deadline = System.currentTimeMillis() + seconds * 1000L
        while (System.currentTimeMillis() < deadline) { if (js(web,script) == "true") return; Thread.sleep(300) }
        fail("Web condition timed out: $script; " + js(web,"JSON.stringify({title:document.title,url:location.href,status:document.getElementById('status')?.textContent,notice:document.getElementById('voiceNotice')?.textContent})"))
    }
    @Test fun liveTabletWebFeatures() {
        assumeTrue(InstrumentationRegistry.getArguments().getString("liveFish") == "true")
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            lateinit var web: WebView
            scenario.onActivity { web = findWeb(it.window.decorView)!! }
            waitFor(web,"!!document.getElementById('start') && !document.getElementById('voiceSelect').disabled")
            assertEquals("true",js(web,"document.getElementById('reference').type === 'file' && !!document.getElementById('trainingView')"))
            assertEquals("true",js(web,"document.getElementById('voiceSelect').options.length >= 1"))
            js(web,"navigateStudio('training-data')")
            assertEquals("true",js(web,"!document.getElementById('trainingView').hidden && document.getElementById('generationView').hidden"))
            js(web,"navigateStudio('generate')")
            assertEquals("false",js(web,"document.getElementById('generationView').hidden"))
        }
    }
    @Test fun liveStreaming() {
        assumeTrue(InstrumentationRegistry.getArguments().getString("liveFish") == "true")
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            lateinit var web: WebView
            scenario.onActivity { web = findWeb(it.window.decorView)!! }
            waitFor(web,"!!document.getElementById('start') && !document.getElementById('voiceSelect').disabled")
            js(web,"fetch('health').then(r=>r.json()).then(d=>window.testServerHealth=d)")
            waitFor(web,"!!window.testServerHealth")
            assumeTrue("Existing synthesis session must finish before live streaming verification",js(web,"window.testServerHealth.busy") == "false")
            try {
            assertEquals("false",js(web,"document.getElementById('reference') === null"))
            assertEquals("false",js(web,"document.getElementById('trainingView') === null"))
            js(web,"document.getElementById('voiceSelect').value=''; selectVoice(); document.getElementById('text').value='안녕하세요. 태블릿 연결 테스트입니다.'; document.getElementById('start').scrollIntoView({block:'center'});")
            Thread.sleep(500)
            val point = JSONArray(js(web,"(()=>{const r=document.getElementById('start').getBoundingClientRect();return [r.x+r.width/2,r.y+r.height/2,window.innerWidth]})()"))
            val location = IntArray(2); var width = 0
            instrument.runOnMainSync { web.getLocationOnScreen(location); width = web.width }
            val scale = width / point.getDouble(2)
            val x = (location[0]+point.getDouble(0)*scale).toFloat(); val y = (location[1]+point.getDouble(1)*scale).toFloat()
            val now = android.os.SystemClock.uptimeMillis()
            instrument.sendPointerSync(MotionEvent.obtain(now,now,MotionEvent.ACTION_DOWN,x,y,0))
            instrument.sendPointerSync(MotionEvent.obtain(now,now+60,MotionEvent.ACTION_UP,x,y,0))
            waitFor(web,"typeof current !== 'undefined' && !!current?.id",90)
            js(web,"document.getElementById('finish').click()")
            waitFor(web,"current?.completed === true",150)
            waitFor(web,"current.played > 0",30)
            assertEquals("true",js(web,"current.received > 0 && current.ctx.state === 'running' && !document.getElementById('result').hidden"))
            assertEquals("true",js(web,"document.getElementById('download').href.includes('/api/sessions/')"))
            } finally {
                js(web,"if (typeof current !== 'undefined' && current?.id && !current.completed) document.getElementById('stop').click()")
            }
        }
    }
}
