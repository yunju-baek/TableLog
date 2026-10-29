package work.yunju.tablelog

import kotlinx.coroutines.runBlocking
import okhttp3.mockwebserver.*
import okhttp3.tls.HandshakeCertificates
import okhttp3.tls.HeldCertificate
import org.junit.Assert.*
import org.junit.Test
import work.yunju.tablelog.ai.*
import java.util.concurrent.TimeUnit

class ServerPairingTest {
    @Test fun codeExchangeAndRedirectProtection() = runBlocking {
        val cert = HeldCertificate.Builder().addSubjectAlternativeName("localhost").build()
        val serverCerts = HandshakeCertificates.Builder().heldCertificate(cert).build()
        val clientCerts = HandshakeCertificates.Builder().addTrustedCertificate(cert.certificate).build()
        val server = MockWebServer().apply { useHttps(serverCerts.sslSocketFactory(),false); start() }
        try {
            val client = AIClient.defaultClient().newBuilder().sslSocketFactory(clientCerts.sslSocketFactory(),clientCerts.trustManager).build()
            val pairing = ServerPairing(client)
            server.enqueue(MockResponse().setBody("""{"speech_model":"whisper","access_token":"synthetic-test-token-of-32-characters"}"""))
            val result = pairing.connect(server.url("/v1").toString(),"ABCD-EFGH-JKLM")
            assertEquals("whisper",result.speechModel)
            val request = server.takeRequest(2,TimeUnit.SECONDS)!!
            assertEquals("/v1/devices/connect",request.path)
            assertNull(request.getHeader("Authorization"))
            assertTrue(request.body.readUtf8().contains("ABCDEFGHJKLM"))
            server.enqueue(MockResponse().setResponseCode(302).setHeader("Location",server.url("/leaked-code")))
            assertTrue(runCatching { pairing.connect(server.url("/v1").toString(),"ABCD-EFGH-JKLM") }.isFailure)
            server.takeRequest(2,TimeUnit.SECONDS)
            assertNull(server.takeRequest(150,TimeUnit.MILLISECONDS))
        } finally { server.shutdown() }
    }
}
