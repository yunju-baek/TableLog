package work.yunju.tablelog.ai

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

enum class SpeechMode(val label: String) { LOCAL("태블릿 로컬"), SERVER("서버") }

data class AISettings(val baseUrl: String = "", val speechModel: String = "", val textModel: String = "", val apiKey: String = "") {
    fun canonicalUrl(): String = baseUrl.trim().toHttpUrlOrNull()?.toString()?.trimEnd('/') ?: baseUrl.trim().trimEnd('/')
    fun validate() {
        val url = baseUrl.trim().toHttpUrlOrNull()
        require(url != null && url.isHttps && url.username.isEmpty() && url.password.isEmpty() && url.query == null && url.fragment == null) { "HTTPS 서버 주소를 입력해 주세요. 예: https://서버주소/v1" }
        require(apiKey.isNotBlank() && apiKey.all { it.code in 33..126 }) { "서버에서 발급한 기기 토큰을 입력해 주세요. 공백·줄바꿈은 사용할 수 없습니다." }
    }
}

class SettingsStore(context: Context) {
    private val prefs = context.getSharedPreferences("ai-settings", Context.MODE_PRIVATE)
    fun speechMode(): SpeechMode = runCatching { SpeechMode.valueOf(prefs.getString("speech-mode", "LOCAL")!!) }.getOrDefault(SpeechMode.LOCAL)
    fun setSpeechMode(mode: SpeechMode) { check(prefs.edit().putString("speech-mode", mode.name).commit()) { "전사 방식을 저장하지 못했습니다." } }
    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey("tablelog-ai", null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder("tablelog-ai", KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
        }.generateKey()
    }
    fun read(): AISettings {
        val secret = prefs.getString("secret", "").orEmpty()
        val apiKey = if (secret.isBlank()) "" else {
            val data = Base64.decode(secret, Base64.NO_WRAP)
            Cipher.getInstance("AES/GCM/NoPadding").apply {
                init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, data.copyOfRange(0, 12)))
                if (prefs.getInt("secret-version", 0) >= 1) updateAAD(prefs.getString("url", "").orEmpty().toByteArray())
            }.doFinal(data.copyOfRange(12, data.size)).toString(Charsets.UTF_8)
        }
        return AISettings(prefs.getString("url", "").orEmpty(), prefs.getString("speech", "").orEmpty(), prefs.getString("text", "").orEmpty(), apiKey)
    }
    fun save(value: AISettings) {
        value.validate()
        val old = runCatching { read() }.getOrNull()
        require(old == null || old.apiKey.isBlank() || old.canonicalUrl() == value.canonicalUrl() || old.apiKey != value.apiKey) {
            "서버 주소가 바뀌었습니다. 새 서버에서 발급한 토큰을 입력해 주세요."
        }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, key()) }
        cipher.updateAAD(value.canonicalUrl().toByteArray())
        val secret = if (value.apiKey.isBlank()) "" else Base64.encodeToString(cipher.iv + cipher.doFinal(value.apiKey.toByteArray()), Base64.NO_WRAP)
        check(prefs.edit().putString("url", value.canonicalUrl()).putInt("secret-version", 1)
            .putString("speech", value.speechModel.trim()).putString("text", value.textModel.trim())
            .putString("secret", secret).commit()) { "설정을 저장하지 못했습니다." }
    }
    fun clear() { check(prefs.edit().remove("url").remove("speech").remove("text").remove("secret").remove("secret-version").commit()) }
}
