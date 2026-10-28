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

data class AISettings(val baseUrl: String = "", val speechModel: String = "", val textModel: String = "", val apiKey: String = "") {
    fun validate() {
        val url = baseUrl.trim().toHttpUrlOrNull()
        require(url != null && url.isHttps && url.username.isEmpty() && url.password.isEmpty() && url.query == null && url.fragment == null) { "HTTPS 서버 주소를 입력해 주세요. 예: https://서버주소/v1" }
        require(!apiKey.contains('\n') && !apiKey.contains('\r')) { "API 키 형식을 확인해 주세요." }
    }
}

class SettingsStore(context: Context) {
    private val prefs = context.getSharedPreferences("ai-settings", Context.MODE_PRIVATE)
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
            }.doFinal(data.copyOfRange(12, data.size)).toString(Charsets.UTF_8)
        }
        return AISettings(prefs.getString("url", "").orEmpty(), prefs.getString("speech", "").orEmpty(), prefs.getString("text", "").orEmpty(), apiKey)
    }
    fun save(value: AISettings) {
        value.validate()
        val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, key()) }
        val secret = if (value.apiKey.isBlank()) "" else Base64.encodeToString(cipher.iv + cipher.doFinal(value.apiKey.toByteArray()), Base64.NO_WRAP)
        check(prefs.edit().putString("url", value.baseUrl.trim().trimEnd('/'))
            .putString("speech", value.speechModel.trim()).putString("text", value.textModel.trim())
            .putString("secret", secret).commit()) { "설정을 저장하지 못했습니다." }
    }
    fun clear() { check(prefs.edit().clear().commit()) }
}
