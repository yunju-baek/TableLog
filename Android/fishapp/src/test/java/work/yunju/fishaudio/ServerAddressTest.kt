package work.yunju.fishaudio

import org.junit.Assert.*
import org.junit.Test

class ServerAddressTest {
    @Test fun onlySelectedHttpsServiceIsAllowed() {
        val base = ServerAddress.MAC_STUDIO
        assertTrue(ServerAddress.allows(base, base + "api/health"))
        assertTrue(ServerAddress.allows(base, base + "download/123?format=m4a"))
        listOf("http://yunju.work/fish-audio/", "https://yunju.work.evil/fish-audio/", "https://yunju.work/other/",
            "https://yunju.work/fish-audio/../admin", "https://yunju.work/fish-audio/%2e%2e/admin",
            "https://user:secret@yunju.work/fish-audio/", "file:///etc/passwd", "javascript:alert(1)").forEach {
            assertFalse(it, ServerAddress.allows(base,it))
        }
    }
    @Test fun configurationRejectsCredentialsAndCleartext() {
        assertEquals(ServerAddress.MAC_STUDIO, ServerAddress.normalize("https://yunju.work/fish-audio"))
        listOf("http://localhost/", "https://u:p@example.com/", "https://example.com/?token=secret").forEach {
            assertThrows(IllegalArgumentException::class.java) { ServerAddress.normalize(it) }
        }
    }
}
