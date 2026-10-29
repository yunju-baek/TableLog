package work.yunju.fishaudio

import android.annotation.SuppressLint
import android.app.Activity
import android.app.AlertDialog
import android.content.Intent
import android.graphics.Color
import android.net.Uri
import android.os.Bundle
import android.view.View
import android.view.WindowInsets
import android.webkit.*
import android.widget.*

/** Tablet client for the existing Fish web UI. S2 stays on the selected Mac server. */
class MainActivity : Activity() {
    private lateinit var web: WebView
    private lateinit var status: TextView
    private var chooser: ValueCallback<Array<Uri>>? = null
    private val prefs by lazy { getSharedPreferences("server", MODE_PRIVATE) }
    private var server = ServerAddress.MAC_STUDIO
    private fun dp(value: Int) = (resources.displayMetrics.density * value).toInt()

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        server = runCatching { ServerAddress.normalize(prefs.getString("url", ServerAddress.MAC_STUDIO)!!) }.getOrDefault(ServerAddress.MAC_STUDIO)
        val root = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setBackgroundColor(Color.rgb(255,250,247)) }
        root.setOnApplyWindowInsetsListener { view, insets ->
            @Suppress("DEPRECATION")
            view.setPadding(insets.systemWindowInsetLeft, insets.systemWindowInsetTop, insets.systemWindowInsetRight, insets.systemWindowInsetBottom)
            insets
        }
        val bar = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = android.view.Gravity.CENTER_VERTICAL; setPadding(dp(12),dp(4),dp(12),dp(4)) }
        status = TextView(this).apply { text = "Fish Audio · 맥 서버"; textSize = 18f; setTextColor(Color.rgb(98,66,207)) }
        bar.addView(status, LinearLayout.LayoutParams(0, dp(52), 1f))
        bar.addView(Button(this).apply { text = "새로고침"; setOnClickListener { web.reload() } })
        bar.addView(Button(this).apply { text = "서버 설정"; setOnClickListener { settings() } })
        root.addView(bar)
        web = WebView(this)
        web.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            allowFileAccess = false
            allowContentAccess = false
            mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
            mediaPlaybackRequiresUserGesture = true
            setSupportMultipleWindows(false)
        }
        CookieManager.getInstance().setAcceptThirdPartyCookies(web, false)
        web.webViewClient = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean = !ServerAddress.allows(server, request.url.toString())
            override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? {
                // No network request leaves the selected service. Local blob audio remains usable.
                return if (request.url.scheme in listOf("https", "http") && !ServerAddress.allows(server, request.url.toString()))
                    WebResourceResponse("text/plain", "UTF-8", 403, "Blocked", emptyMap(), java.io.ByteArrayInputStream(byteArrayOf())) else null
            }
            override fun onPageFinished(view: WebView, url: String) { status.text = if (server == ServerAddress.MAC_STUDIO) "Fish Audio · 맥스튜디오" else "Fish Audio · 내 서버" }
            override fun onReceivedError(view: WebView, request: WebResourceRequest, error: WebResourceError) {
                if (request.isForMainFrame) status.text = "연결 실패 · 서버 설정 확인"
            }
        }
        web.webChromeClient = object : WebChromeClient() {
            override fun onShowFileChooser(view: WebView, callback: ValueCallback<Array<Uri>>, params: FileChooserParams): Boolean {
                chooser?.onReceiveValue(null); chooser = callback
                val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType("audio/*")
                intent.putExtra(Intent.EXTRA_ALLOW_MULTIPLE, params.mode == FileChooserParams.MODE_OPEN_MULTIPLE)
                try { @Suppress("DEPRECATION") startActivityForResult(intent, 20) }
                catch (_: Exception) { chooser?.onReceiveValue(null); chooser = null; toast("파일 선택기를 열지 못했습니다.") }
                return true
            }
            override fun onPermissionRequest(request: PermissionRequest) { request.deny() }
        }
        web.setDownloadListener { url, _, _, _, _ ->
            if (ServerAddress.allows(server, url)) runCatching { startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url))) }.onFailure { toast("다운로드할 브라우저가 필요합니다.") }
            else toast("선택한 서버의 다운로드 링크만 열 수 있습니다.")
        }
        root.addView(web, LinearLayout.LayoutParams(-1, 0, 1f))
        setContentView(root)
        web.loadUrl(server)
    }

    private fun settings() {
        val layout = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(dp(24),dp(12),dp(24),0) }
        val input = EditText(this).apply { setSingleLine(); setText(server); hint = "https://서버주소/fish-audio/"; inputType = android.text.InputType.TYPE_CLASS_TEXT or android.text.InputType.TYPE_TEXT_VARIATION_URI }
        layout.addView(TextView(this).apply { text = "합성은 선택한 서버에서 실행합니다. 맥스튜디오에서는 기존 목소리·학습·스트리밍 기능을 그대로 사용합니다. 이 앱에 S2 모델은 포함되지 않습니다." })
        layout.addView(Button(this).apply { text = "맥스튜디오 선택"; setOnClickListener { input.setText(ServerAddress.MAC_STUDIO) } })
        layout.addView(input)
        val dialog = AlertDialog.Builder(this).setTitle("Fish Audio 서버").setView(layout).setNegativeButton("취소",null).setPositiveButton("연결",null).create()
        dialog.setOnShowListener {
            dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener {
                runCatching { ServerAddress.normalize(input.text.toString()) }.onSuccess { next ->
                    if (next != server) { web.stopLoading(); web.clearHistory(); web.clearCache(true) }
                    server = next; prefs.edit().putString("url", next).apply(); web.loadUrl(next); dialog.dismiss()
                }.onFailure { input.error = it.message ?: "HTTPS 주소를 확인해 주세요." }
            }
        }
        dialog.show()
    }

    @Deprecated("Activity result compatibility")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode,resultCode,data)
        if (requestCode == 20) {
            val uris = if (resultCode != RESULT_OK || data == null) null else data.clipData?.let { clip -> Array(clip.itemCount) { clip.getItemAt(it).uri } } ?: data.data?.let { arrayOf(it) }
            chooser?.onReceiveValue(uris?.filter { it.scheme == "content" }?.toTypedArray()); chooser = null
        }
    }
    @Deprecated("Activity back compatibility")
    override fun onBackPressed() { if (web.canGoBack()) web.goBack() else super.onBackPressed() }
    override fun onDestroy() { chooser?.onReceiveValue(null); chooser = null; web.destroy(); super.onDestroy() }
    private fun toast(value: String) { Toast.makeText(this,value,Toast.LENGTH_LONG).show() }
}
