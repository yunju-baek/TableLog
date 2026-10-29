package work.yunju.fishaudio

import java.net.URI

object ServerAddress {
    const val MAC_STUDIO = "https://yunju.work/fish-audio/"
    fun normalize(value: String): String {
        val uri = URI(value.trim())
        require(uri.scheme == "https" && !uri.host.isNullOrBlank() && uri.userInfo == null && uri.query == null && uri.fragment == null) {
            "사용자 정보·쿼리가 없는 HTTPS 주소를 입력해 주세요."
        }
        require(uri.rawPath.orEmpty().split('/').none { it == ".." || it == "." || it.contains('%') }) { "올바른 서버 경로를 입력해 주세요." }
        return uri.toASCIIString().trimEnd('/') + "/"
    }
    fun allows(base: String, target: String): Boolean = runCatching {
        val root = URI(normalize(base)); val next = URI(target)
        val path = next.rawPath.orEmpty()
        next.scheme == "https" && root.host.equals(next.host, ignoreCase = true) && root.port == next.port &&
            next.userInfo == null && path.startsWith(root.rawPath) &&
            path.split('/').none { it == ".." || it == "." || it.contains('%') || it.contains('\\') }
    }.getOrDefault(false)
}
