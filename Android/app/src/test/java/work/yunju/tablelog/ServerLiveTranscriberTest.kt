package work.yunju.tablelog

import kotlinx.coroutines.*
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.tls.HandshakeCertificates
import okhttp3.tls.HeldCertificate
import org.junit.Assert.*
import org.junit.Test
import work.yunju.tablelog.ai.*
import work.yunju.tablelog.audio.WavFile
import work.yunju.tablelog.data.Utterance
import java.io.File
import java.io.RandomAccessFile
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

class ServerLiveTranscriberTest {
    @Test fun sendsWhileRecordingFlushesFinalRangeAndSkipsSilence() = runBlocking {
        val certificate = HeldCertificate.Builder().addSubjectAlternativeName("localhost").build()
        val serverCertificates = HandshakeCertificates.Builder().heldCertificate(certificate).build()
        val clientCertificates = HandshakeCertificates.Builder().addTrustedCertificate(certificate.certificate).build()
        val server = MockWebServer().apply { useHttps(serverCertificates.sslSocketFactory(), false); start() }
        val file = File.createTempFile("tablelog-live", ".wav")
        try {
            val transport = AIClient.defaultClient().newBuilder().sslSocketFactory(clientCertificates.sslSocketFactory(), clientCertificates.trustManager).build()
            val client = AIClient(AISettings(server.url("/v1").toString(), "test-speech", "", "synthetic-token"), transport)
            repeat(2) { server.enqueue(MockResponse().setBody("""{"segments":[{"start":0,"end":1,"text":"live result"}]}""")) }
            val bytes = AtomicLong(0); val finished = AtomicBoolean(false)
            val first = CompletableDeferred<Unit>(); val output = mutableListOf<Utterance>()
            RandomAccessFile(file, "rw").use { writer ->
                writer.write(WavFile.header(0))
                val job = async { ServerLiveTranscriber(client).follow(file, bytes::get, finished::get, { output += it; first.complete(Unit) }, {}) }
                try {
                    // Five seconds of synthetic PCM followed by a quiet boundary.
                    writer.write(ByteArray(5 * WavFile.BYTES_PER_SECOND) { if (it % 2 == 0) 0 else 8 })
                    writer.write(ByteArray(WavFile.BYTES_PER_SECOND / 2)); bytes.set(writer.length() - 44)
                    withTimeout(10_000) { first.await() }
                    assertFalse(finished.get()); assertEquals(1, server.requestCount)
                    writer.write(ByteArray(WavFile.BYTES_PER_SECOND) { if (it % 2 == 0) 0 else 8 })
                    bytes.set(writer.length() - 44); finished.set(true)
                    withTimeout(10_000) { job.await() }
                    assertEquals(listOf(0.0, 5.5), output.map { it.start })
                    assertEquals(2, server.requestCount)
                    val requests = List(2) { server.takeRequest() }
                    assertTrue(requests.all { it.getHeader("Authorization") == "Bearer synthetic-token" && it.bodySize < 200_000 })
                } finally { finished.set(true); job.cancelAndJoin() }
            }
            file.writeBytes(WavFile.header(6L * WavFile.BYTES_PER_SECOND) + ByteArray(6 * WavFile.BYTES_PER_SECOND))
            ServerLiveTranscriber(client).follow(file, { file.length() - 44 }, { true }, { fail("Silence must not be sent") }, {})
            assertEquals(2, server.requestCount)
        } finally { file.delete(); server.shutdown() }
    }
}
