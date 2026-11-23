package work.yunju.tablelog.ai

import android.app.*
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.*
import android.util.AtomicFile
import androidx.core.app.NotificationCompat
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import work.yunju.tablelog.MainActivity
import work.yunju.tablelog.R
import work.yunju.tablelog.TableLogApplication
import work.yunju.tablelog.audio.RecordingService
import work.yunju.tablelog.data.*
import java.io.File

data class LocalAiState(val running: Boolean = false, val message: String? = null, val completedMeetingId: String? = null)

class LocalAiService : Service() {
    companion object {
        const val INSTALL = "work.yunju.tablelog.INSTALL_LOCAL_MODEL"
        const val TRANSCRIBE = "work.yunju.tablelog.TRANSCRIBE_LOCAL"
        const val CANCEL = "work.yunju.tablelog.CANCEL_LOCAL"
        private val mutableState = MutableStateFlow(LocalAiState())
        val state = mutableState.asStateFlow()
        fun proposalFile(context: Context, id: String): AtomicFile {
            java.util.UUID.fromString(id)
            return AtomicFile(File(context.filesDir, "meetings/$id/local-proposal.json"))
        }
        fun readProposal(context: Context, id: String): Meeting? = runCatching {
            proposalFile(context, id).openRead().bufferedReader().use { MeetingCodec.decode(it.readText()) }
        }.getOrNull()?.also { require(it.id == id) }
        fun dismissMessage() { if (!state.value.running) mutableState.value = LocalAiState() }
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var job: Job? = null
    private var wake: PowerManager.WakeLock? = null
    override fun onBind(intent: Intent?) = null
    override fun onCreate() {
        super.onCreate()
        getSystemService(NotificationManager::class.java).createNotificationChannel(NotificationChannel("local-ai", "기기 내 전사·모델 설치", NotificationManager.IMPORTANCE_LOW))
    }
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == CANCEL) { job?.cancel(); if (job == null) stopSelf(); return START_NOT_STICKY }
        if (job != null) return START_NOT_STICKY
        val install = intent?.action == INSTALL
        if (!install && intent?.action != TRANSCRIBE) { stopSelf(); return START_NOT_STICKY }
        try {
            check(RecordingService.state.value.meetingId == null) { "녹음을 저장한 뒤 로컬 AI를 실행해 주세요." }
            val label = if (install) "한국어 모델 설치 준비 중" else "기기에서 전사 준비 중"
            val type = if (!install && Build.VERSION.SDK_INT >= 35) ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROCESSING else ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
            if (Build.VERSION.SDK_INT >= 29) startForeground(2, notification(label), type) else startForeground(2, notification(label))
            mutableState.value = LocalAiState(true, label)
            wake = getSystemService(PowerManager::class.java).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "TableLog:LocalAI").apply {
                setReferenceCounted(false); acquire(6 * 60 * 60 * 1000L)
            }
            val id = intent?.getStringExtra("meetingId")
            job = scope.launch {
                try {
                    val models = LocalModelStore(this@LocalAiService)
                    if (install) {
                        var previous = -1
                        models.install { percent -> if (percent != previous) { previous = percent; update("한국어 모델 설치 $percent%") } }
                        mutableState.value = LocalAiState(message = "한국어 모델 설치 완료. 이제 인터넷 없이 전사할 수 있습니다.")
                    } else {
                        val app = application as TableLogApplication
                        check(app.ready.value) { "회의 목록을 불러온 뒤 다시 실행해 주세요." }
                        val meeting = app.repository.get(id ?: error("회의를 찾을 수 없습니다.")) ?: error("회의를 찾을 수 없습니다.")
                        check(!meeting.deleted && meeting.status !in listOf("recording", "paused")) { "저장한 회의를 선택해 주세요." }
                        val audio = app.repository.audioFile(meeting) ?: error("전사할 녹음이 없습니다.")
                        val utterances = LocalTranscriber(models).transcribe(audio) { update("기기에서 전사 $it% · 서버 전송 없음") }
                        ensureActive()
                        check(utterances.isNotEmpty()) { "인식된 발언이 없습니다. 녹음을 재생해 확인해 주세요. 원본은 보존되어 있습니다." }
                        val file = proposalFile(this@LocalAiService, meeting.id)
                        val out = file.startWrite()
                        try {
                            out.write(MeetingCodec.encode(meeting.copy(utterances = utterances)).toByteArray())
                            file.finishWrite(out)
                        } catch (e: Exception) { file.failWrite(out); throw e }
                        mutableState.value = LocalAiState(message = "로컬 전사가 끝났습니다. 결과를 검토해 주세요.", completedMeetingId = meeting.id)
                    }
                } catch (e: CancellationException) {
                    mutableState.value = LocalAiState(message = "로컬 작업을 취소했습니다. 녹음 원본은 보존했습니다.")
                } catch (e: Exception) {
                    mutableState.value = LocalAiState(message = e.message ?: "로컬 작업을 완료하지 못했습니다.")
                } catch (e: LinkageError) {
                    mutableState.value = LocalAiState(message = "이 기기에서 로컬 음성 엔진을 불러오지 못했습니다.")
                } finally {
                    if (wake?.isHeld == true) wake?.release()
                    stopForeground(STOP_FOREGROUND_REMOVE)
                    stopSelf()
                }
            }
        } catch (e: Exception) {
            mutableState.value = LocalAiState(message = e.message ?: "로컬 작업을 시작하지 못했습니다.")
            stopSelf()
        }
        return START_NOT_STICKY
    }
    private fun update(text: String) {
        mutableState.value = LocalAiState(true, text)
        getSystemService(NotificationManager::class.java).notify(2, notification(text))
    }
    private fun notification(text: String): Notification {
        val open = PendingIntent.getActivity(this, 2, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val cancel = PendingIntent.getService(this, 3, Intent(this, LocalAiService::class.java).setAction(CANCEL), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        return NotificationCompat.Builder(this, "local-ai").setSmallIcon(R.drawable.ic_tablelog)
            .setContentTitle("테이블로그 · 로컬 AI").setContentText(text).setContentIntent(open)
            .setOngoing(true).setOnlyAlertOnce(true).addAction(0, "취소", cancel).build()
    }
    override fun onTimeout(startId: Int, fgsType: Int) {
        job?.cancel(); stopForeground(STOP_FOREGROUND_REMOVE); stopSelf()
    }
    override fun onDestroy() {
        scope.cancel()
        if (wake?.isHeld == true) wake?.release()
        super.onDestroy()
    }
}
