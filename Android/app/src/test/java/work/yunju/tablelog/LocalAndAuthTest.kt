package work.yunju.tablelog

import kotlinx.coroutines.*
import okhttp3.mockwebserver.*
import okhttp3.tls.HandshakeCertificates
import okhttp3.tls.HeldCertificate
import okio.Buffer
import org.junit.Assert.*
import org.junit.Test
import work.yunju.tablelog.ai.*
import work.yunju.tablelog.audio.WavFile
import java.io.File
import java.nio.file.Files
import java.security.MessageDigest
import java.util.concurrent.TimeUnit

class LocalAndAuthTest {
    private fun hash(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
    private fun withServer(block: suspend (MockWebServer, okhttp3.OkHttpClient) -> Unit) = runBlocking {
        val cert = HeldCertificate.Builder().addSubjectAlternativeName("localhost").build()
        val serverCerts = HandshakeCertificates.Builder().heldCertificate(cert).build()
        val clientCerts = HandshakeCertificates.Builder().addTrustedCertificate(cert.certificate).build()
        val server = MockWebServer().apply { useHttps(serverCerts.sslSocketFactory(), false); start() }
        val client = AIClient.defaultClient().newBuilder().sslSocketFactory(clientCerts.sslSocketFactory(), clientCerts.trustManager).build()
        try { block(server, client) } finally { server.shutdown() }
    }
    @Test fun resumesVerifiedModelAndRejectsCorruptBytes() = withServer { server, client ->
        val root = Files.createTempDirectory("model-download-test").toFile()
        try {
            val bytes = "synthetic model bytes, never an actual model".toByteArray()
            val target = File(root, "model.onnx")
            File(root, "model.onnx.part").writeBytes(bytes.take(5).toByteArray())
            val spec = ModelFile(target.name, server.url("/model").toString(), bytes.size.toLong(), hash(bytes))
            server.enqueue(MockResponse().setResponseCode(206).setHeader("Content-Range", "bytes 5-${bytes.size - 1}/${bytes.size}")
                .setBody(Buffer().write(bytes, 5, bytes.size - 5)))
            ModelDownload(client).fetch(spec, target) {}
            assertArrayEquals(bytes, target.readBytes())
            val request = server.takeRequest(2, TimeUnit.SECONDS)!!
            assertEquals("bytes=5-", request.getHeader("Range"))
            assertNull(request.getHeader("Authorization"))
            target.delete()
            server.enqueue(MockResponse().setBody(Buffer().write(ByteArray(bytes.size))))
            val failure = runCatching { ModelDownload(client).fetch(spec, target) {} }.exceptionOrNull()
            assertNotNull(failure)
            assertFalse(target.exists())
            assertFalse(File(root, "model.onnx.part").exists())
        } finally { root.deleteRecursively() }
    }
    @Test fun interruptedModelDownloadLeavesOnlyResumablePartial() = withServer { server, client ->
        val root = Files.createTempDirectory("model-cancel-test").toFile()
        try {
            val bytes = ByteArray(500_000) { 42 }
            val target = File(root, "model.onnx")
            val spec = ModelFile(target.name, server.url("/model").toString(), bytes.size.toLong(), hash(bytes))
            server.enqueue(MockResponse().setBody(Buffer().write(bytes)).throttleBody(4096, 50, TimeUnit.MILLISECONDS))
            coroutineScope {
                val job = launch { ModelDownload(client).fetch(spec, target) {} }
                withTimeout(5_000) { while (File(root, "model.onnx.part").length() == 0L) delay(10) }
                job.cancelAndJoin()
                assertFalse(target.exists())
                val partial = File(root, "model.onnx.part")
                assertTrue(partial.length() in 1 until bytes.size.toLong())
                val length = partial.length(); delay(100)
                assertEquals(length, partial.length())
            }
        } finally { root.deleteRecursively() }
    }
    @Test fun connectionProbeSendsOnlyTokenAndDoesNotFollowRedirects() = withServer { server, client ->
        val settings = AISettings(server.url("/v1").toString(), apiKey = "device-test-token")
        server.enqueue(MockResponse().setBody("""{"data":[{"id":"speech"}]}"""))
        assertTrue(AIClient(settings, client).checkConnection().contains("1개"))
        val request = server.takeRequest(2, TimeUnit.SECONDS)!!
        assertEquals("GET", request.method); assertEquals("/v1/models", request.path)
        assertEquals(0L, request.bodySize); assertEquals("Bearer device-test-token", request.getHeader("Authorization"))
        for ((code, text) in listOf(401 to "인증", 403 to "권한")) {
            server.enqueue(MockResponse().setResponseCode(code))
            assertTrue(runCatching { AIClient(settings, client).checkConnection() }.exceptionOrNull()!!.message!!.contains(text))
            server.takeRequest(2, TimeUnit.SECONDS)
        }
        server.enqueue(MockResponse().setResponseCode(302).setHeader("Location", server.url("/stolen-token")))
        assertTrue(runCatching { AIClient(settings, client).checkConnection() }.isFailure)
        server.takeRequest(2, TimeUnit.SECONDS)
        assertNull(server.takeRequest(150, TimeUnit.MILLISECONDS))
    }
    @Test fun nativeInputRejectsMismatchedOrTruncatedWaveHeader() {
        val file = File.createTempFile("wave-validation", ".wav")
        try {
            file.writeBytes(WavFile.header(32000) + ByteArray(32000))
            assertEquals(1.0, LocalTranscriber.validateWave(file), 0.0)
            file.writeBytes(WavFile.header(64000) + ByteArray(32000))
            assertThrows(IllegalArgumentException::class.java) { LocalTranscriber.validateWave(file) }
            file.writeBytes(WavFile.header(1) + byteArrayOf(0))
            assertThrows(IllegalArgumentException::class.java) { LocalTranscriber.validateWave(file) }
        } finally { file.delete() }
    }
}
