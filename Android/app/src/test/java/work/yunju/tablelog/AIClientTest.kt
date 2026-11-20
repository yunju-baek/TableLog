package work.yunju.tablelog

import kotlinx.coroutines.runBlocking
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.tls.HandshakeCertificates
import okhttp3.tls.HeldCertificate
import org.junit.Assert.*
import org.junit.Test
import work.yunju.tablelog.ai.*
import work.yunju.tablelog.audio.WavFile
import work.yunju.tablelog.data.*
import java.io.File
import java.util.concurrent.TimeUnit

class AIClientTest {
    @Test fun sendsBoundedWavChunksAndCombinesGlobalTimestamps() = runBlocking {
        val cert = HeldCertificate.Builder().addSubjectAlternativeName("localhost").build()
        val serverCerts = HandshakeCertificates.Builder().heldCertificate(cert).build()
        val clientCerts = HandshakeCertificates.Builder().addTrustedCertificate(cert.certificate).build()
        val server = MockWebServer().apply { useHttps(serverCerts.sslSocketFactory(), false); start() }
        val file = File.createTempFile("tablelog-api-test", ".wav")
        try {
            val client = AIClient.defaultClient().newBuilder().sslSocketFactory(clientCerts.sslSocketFactory(), clientCerts.trustManager).build()
            val settings = AISettings(server.url("/v1").toString(), "test-speech", "test-text", "synthetic-test-key")
            repeat(2) { server.enqueue(MockResponse().setBody("""{"segments":[{"start":0,"end":1,"text":"테스트 발언"}]}""")) }
            val size = 301 * WavFile.BYTES_PER_SECOND
            file.writeBytes(WavFile.header(size.toLong()) + ByteArray(size))
            val output = AIClient(settings, client).transcribe(file) {}
            assertEquals(listOf(1, 2), output.map { it.id })
            assertEquals(listOf(0.0, 300.0), output.map { it.start })
            val first = server.takeRequest(3, TimeUnit.SECONDS)!!
            assertEquals("/v1/audio/transcriptions", first.path)
            assertEquals("Bearer synthetic-test-key", first.getHeader("Authorization"))
            val body = first.body.readByteArray()
            assertTrue(body.size < 10_000_000)
            assertTrue(body.toString(Charsets.ISO_8859_1).contains("RIFF"))
            val second = server.takeRequest(3, TimeUnit.SECONDS)!!
            assertTrue(second.bodySize < 34_000)
            server.enqueue(MockResponse().setBody("""{"choices":[{"message":{"content":"## 결정 사항\n\n확인 필요"}}]}"""))
            val minutes = AIClient(settings, client).minutes(Meeting(title = "합성 회의", utterances = output))
            assertTrue(minutes.contains("확인 필요"))
            assertEquals("/v1/chat/completions", server.takeRequest(3, TimeUnit.SECONDS)!!.path)
        } finally { file.delete(); server.shutdown() }
    }
}
