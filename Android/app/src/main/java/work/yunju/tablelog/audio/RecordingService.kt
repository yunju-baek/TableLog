package work.yunju.tablelog.audio

import android.Manifest
import android.app.*
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.*
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.flow.MutableStateFlow
import work.yunju.tablelog.ai.*
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.flow.asStateFlow
import work.yunju.tablelog.MainActivity
import work.yunju.tablelog.R
import work.yunju.tablelog.TableLogApplication
import work.yunju.tablelog.data.*
import java.io.RandomAccessFile
import kotlin.concurrent.thread
import kotlin.math.abs

data class RecordingState(
    val meetingId: String? = null, val paused: Boolean = false,
    val seconds: Double = 0.0, val level: Float = 0f,
    val error: String? = null,
    val starting: Boolean = false, val finishing: Boolean = false,
    val live: Boolean = false, val modelName: String = "", val processedSeconds: Double = 0.0,
    val transcriptionError: String? = null, val aiMessage: String? = null,
) { val running get() = starting || meetingId != null }

class RecordingService : Service() {
    companion object {
        const val START = "work.yunju.tablelog.START"
        const val PAUSE = "work.yunju.tablelog.PAUSE"
        const val RESUME = "work.yunju.tablelog.RESUME"
        const val CANCEL_TRANSCRIPTION = "work.yunju.tablelog.CANCEL_LIVE"
        const val STOP = "work.yunju.tablelog.STOP"
        private val mutableState = MutableStateFlow(RecordingState())
        val state = mutableState.asStateFlow()
    }
    @Volatile private var stopping = false
    @Volatile private var paused = false
    private var worker: Thread? = null
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var liveJob: Job? = null
    private var summaryJob: Job? = null
    private val main = Handler(Looper.getMainLooper())
    private val repository get() = (application as TableLogApplication).repository
    override fun onBind(intent: Intent?) = null

    override fun onCreate() {
        super.onCreate()
        getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel("recording", "회의 녹음", NotificationManager.IMPORTANCE_LOW))
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            START -> if (worker == null) {
                try {
                    check(ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) { "마이크 권한이 필요합니다." }
                    check((application as TableLogApplication).ready.value) { "회의 목록을 불러온 뒤 다시 시도해 주세요." }
                    check(!work.yunju.tablelog.ai.LocalAiService.state.value.running) { "로컬 AI 작업을 완료하거나 취소한 뒤 녹음해 주세요." }
                    val settings = SettingsStore(this)
                    val live = intent.getBooleanExtra("live", settings.liveTranscription())
                    val mode = intent.getStringExtra("speechMode")?.let { SpeechMode.valueOf(it) } ?: settings.speechMode()
                    val models = if (live && mode == SpeechMode.LOCAL) LocalModelStore(this, intent.getStringExtra("modelId")) else null
                    check(models == null || models.installed()) { "설정에서 선택한 모델을 설치하거나 자동 전사를 꺼 주세요." }
                    val server = if (live && mode == SpeechMode.SERVER) settings.read().also {
                        it.validate()
                        check(it.speechModel.isNotBlank()) { "서버 음성 모델을 설정해 주세요." }
                        check(intent.getStringExtra("approvedServer") == it.canonicalUrl()) { "녹음 시작 화면에서 전송할 서버를 확인해 주세요." }
                    } else null
                    val assistant = if (live && intent.getBooleanExtra("autoMinutes", false)) settings.read().also {
                        it.validate(); check(it.textModel.isNotBlank()) { "회의 AI 모델을 설정해 주세요." }
                        check(intent.getStringExtra("approvedTextServer") == it.canonicalUrl()) { "회의 AI 전송 대상을 확인해 주세요." }
                    } else null
                    mutableState.value = RecordingState(starting = true)
                    val notification = notification(false)
                    if (Build.VERSION.SDK_INT >= 30) startForeground(1, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
                    else startForeground(1, notification)
                    stopping = false; paused = false
                    val title = intent.getStringExtra("title")?.trim()?.take(500).orEmpty().ifBlank { "새 회의" }
                    worker = thread(name = "TableLog recorder") { record(title, models, server, assistant) }
                } catch (e: Exception) {
                    mutableState.value = RecordingState(error = "녹음을 시작할 수 없습니다. ${e.message.orEmpty()}")
                    stopSelf()
                }
            }
            PAUSE -> { paused = true; updateNotification() }
            RESUME -> { paused = false; updateNotification() }
            STOP -> { stopping = true }
            CANCEL_TRANSCRIPTION -> { liveJob?.cancel(); summaryJob?.cancel() }
            else -> if (worker == null) stopSelf()
        }
        return START_NOT_STICKY
    }

    private fun notification(isPaused: Boolean): Notification {
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        fun action(action: String, code: Int) = PendingIntent.getService(this, code,
            Intent(this, RecordingService::class.java).setAction(action), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        if (state.value.finishing) return NotificationCompat.Builder(this, "recording")
            .setSmallIcon(R.drawable.ic_mic).setContentTitle("테이블로그 · 회의 기록 마무리")
            .setContentText("녹음은 저장되었습니다. 남은 전사와 회의 AI 작업을 마무리합니다.").setContentIntent(open).setOngoing(true).setOnlyAlertOnce(true)
            .addAction(0, "처리 중지", action(CANCEL_TRANSCRIPTION, 3)).build()
        return NotificationCompat.Builder(this, "recording")
            .setSmallIcon(R.drawable.ic_mic).setContentTitle(if (isPaused) "테이블로그 · 일시정지" else "테이블로그 · 녹음 중")
            .setContentText("탭하여 회의로 돌아가기").setContentIntent(open).setOngoing(true).setOnlyAlertOnce(true)
            .addAction(0, if (isPaused) "녹음 재개" else "일시정지", action(if (isPaused) RESUME else PAUSE, 1))
            .addAction(0, "저장하고 종료", action(STOP, 2)).build()
    }
    private fun updateNotification() {
        if (worker != null) getSystemService(NotificationManager::class.java).notify(1, notification(paused))
    }

    @Suppress("MissingPermission")
    private fun record(title: String, models: LocalModelStore?, server: AISettings?, assistant: AISettings?) {
        val live = models != null || server != null
        val modelName = models?.definition?.name ?: server?.let { "서버 · ${it.speechModel}" }.orEmpty()
        val available = AtomicLong(0)
        val ended = AtomicBoolean(false)
        val transcriptDone = AtomicBoolean(false)
        var recorder: AudioRecord? = null
        var file: RandomAccessFile? = null
        var meeting: Meeting? = null
        var bytes = 0L
        var failure: String? = null
        val wake = getSystemService(PowerManager::class.java).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "TableLog:Recording").apply { setReferenceCounted(false) }
        try {
            val minimum = AudioRecord.getMinBufferSize(WavFile.SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
            check(minimum > 0) { "이 기기에서 녹음 형식을 지원하지 않습니다." }
            recorder = AudioRecord.Builder().setAudioSource(MediaRecorder.AudioSource.MIC)
                .setAudioFormat(AudioFormat.Builder().setSampleRate(WavFile.SAMPLE_RATE)
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT).setChannelMask(AudioFormat.CHANNEL_IN_MONO).build())
                .setBufferSizeInBytes(maxOf(minimum, 6400)).build()
            check(recorder.state == AudioRecord.STATE_INITIALIZED) { "마이크를 열 수 없습니다." }
            meeting = repository.save(Meeting(title = title, audioName = "recording.wav", status = "recording",
                transcriptionModel = modelName, transcriptionStatus = if (live) "running" else ""))
            file = RandomAccessFile(repository.audioFile(meeting)!!, "rw")
            file.write(WavFile.header(0))
            mutableState.value = RecordingState(meetingId = meeting.id, live = live, modelName = modelName)
            if (live) {
                val id = meeting.id
                val audio = repository.audioFile(meeting)!!
                liveJob = scope.launch {
                    var status = "complete"
                    try {
                        val append: (Utterance) -> Unit = { repository.appendLive(id, it) }
                        val progress: (Long) -> Unit = { count -> mutableState.update { it.copy(processedSeconds = count.toDouble() / WavFile.BYTES_PER_SECOND) } }
                        if (models != null) LocalTranscriber(models).follow(audio, available::get, ended::get, append, progress)
                        else ServerLiveTranscriber(AIClient(server!!, language = LocalModelStore(this@RecordingService).language)).follow(audio, available::get, ended::get, append, progress)
                    } catch (e: CancellationException) {
                        status = "interrupted"
                        mutableState.update { it.copy(transcriptionError = "자동 전사를 중지했습니다. 녹음과 완료된 녹취는 보관합니다.") }
                    } catch (e: Exception) {
                        status = "interrupted"
                        mutableState.update { it.copy(transcriptionError = "자동 전사 중단: ${e.message.orEmpty()} 녹음 파일과 완료된 녹취는 보관합니다.") }
                    } catch (e: LinkageError) {
                        status = "interrupted"
                        mutableState.update { it.copy(transcriptionError = "음성 엔진을 열지 못했습니다. 녹음 파일과 완료된 녹취는 보관합니다.") }
                    } finally {
                        runCatching { repository.update(id, snapshot = false) { it.copy(transcriptionStatus = status) } }
                    }
                }
            }
            if (assistant != null) {
                val id = meeting.id
                summaryJob = scope.launch {
                    val ai = MeetingAI(AIClient(assistant))
                    var next = SystemClock.elapsedRealtime() + 120_000
                    var count = 0
                    try {
                        while (!transcriptDone.get()) {
                            delay(1000)
                            if (SystemClock.elapsedRealtime() < next) continue
                            next = SystemClock.elapsedRealtime() + 120_000
                            val snapshot = repository.get(id) ?: break
                            if (snapshot.utterances.size <= count) continue
                            try {
                                mutableState.update { it.copy(aiMessage = "진행 요약 작성 중") }
                                val text = ai.summary(snapshot)
                                repository.update(id, snapshot = false) { it.copy(summary = text) }
                                count = snapshot.utterances.size
                            } catch (e: CancellationException) { throw e }
                            catch (e: Exception) { mutableState.update { it.copy(aiMessage = "요약 대기 · ${e.message.orEmpty()}") } }
                        }
                        val snapshot = repository.get(id)
                        if (snapshot != null && snapshot.utterances.isNotEmpty()) {
                            mutableState.update { it.copy(aiMessage = "종료 후 회의록 작성 중") }
                            val text = ai.minutes(snapshot)
                            repository.update(id, snapshot = false) { it.copy(automaticMinutes = text) }
                        }
                    } catch (e: CancellationException) { /* Original and completed drafts remain. */ }
                    catch (e: Exception) { mutableState.update { it.copy(transcriptionError = "자동 회의록을 완료하지 못했습니다. ${e.message.orEmpty()}") } }
                    finally { mutableState.update { it.copy(aiMessage = null) } }
                }
            }
            wake.acquire(10 * 60 * 1000L)
            recorder.startRecording()
            check(recorder.recordingState == AudioRecord.RECORDSTATE_RECORDING) { "다른 앱의 마이크 사용을 확인해 주세요." }
            var wasPaused = false
            var checkpointBytes = 0L
            val buffer = ByteArray(3200)
            fun checkpoint(status: String) {
                file.seek(0); file.write(WavFile.header(bytes)); file.seek(WavFile.HEADER_SIZE + bytes); file.fd.sync()
                repository.update(meeting.id, snapshot = false) { it.copy(durationSeconds = bytes.toDouble() / WavFile.BYTES_PER_SECOND, status = status) }
                checkpointBytes = bytes
            }
            while (!stopping) {
                if (paused) {
                    if (!wasPaused) {
                        recorder.stop(); checkpoint("paused"); wasPaused = true
                        if (wake.isHeld && liveJob?.isActive != true && summaryJob?.isActive != true) wake.release()
                        mutableState.update { it.copy(paused = true, level = 0f) }
                    }
                    if ((liveJob?.isActive == true || summaryJob?.isActive == true) && !wake.isHeld) wake.acquire(10 * 60 * 1000L)
                    Thread.sleep(50)
                    continue
                }
                if (wasPaused) {
                    wake.acquire(10 * 60 * 1000L); recorder.startRecording(); wasPaused = false
                    checkpoint("recording")
                    mutableState.update { it.copy(paused = false) }
                }
                val read = recorder.read(buffer, 0, buffer.size, AudioRecord.READ_BLOCKING)
                check(read >= 0) { "마이크 연결이 끊어졌습니다. (오류 $read)" }
                if (read == 0) { Thread.sleep(20); continue }
                check(bytes + read < 0xfffffff0L) { "파일 크기 한도에 도달해 녹음을 저장합니다." }
                file.write(buffer, 0, read); bytes += read; available.set(bytes)
                var peak = 0
                for (i in 0 until read - 1 step 2) {
                    val value = ((buffer[i].toInt() and 255) or (buffer[i + 1].toInt() shl 8)).toShort().toInt()
                    peak = maxOf(peak, abs(value))
                }
                mutableState.update { it.copy(seconds = bytes.toDouble() / WavFile.BYTES_PER_SECOND, level = peak / 32768f, paused = false) }
                if (bytes - checkpointBytes >= 5L * WavFile.BYTES_PER_SECOND) {
                    checkpoint("recording")
                    // Non-reference-counted lease, renewed while the recording loop is alive.
                    wake.acquire(10 * 60 * 1000L)
                }
            }
        } catch (e: Exception) {
            failure = "녹음이 중단되었습니다. ${e.message.orEmpty()}"
        } finally {
            runCatching { recorder?.stop() }; runCatching { recorder?.release() }
            runCatching {
                file?.let { it.seek(0); it.write(WavFile.header(bytes)); it.fd.sync() }
            }.onFailure { failure = "녹음 파일을 마무리하지 못했습니다. 저장 공간을 확인해 주세요." }
            runCatching { file?.close() }
            meeting?.let { m ->
                runCatching { repository.update(m.id, snapshot = false) {
                    it.copy(status = if (failure == null) "saved" else "interrupted", endedAt = System.currentTimeMillis(), durationSeconds = bytes.toDouble() / WavFile.BYTES_PER_SECOND)
                } }.onFailure { failure = "저장 정보를 기록하지 못했습니다. 다음 실행에서 녹음 복구를 시도합니다." }
            }
            ended.set(true)
            if (liveJob?.isActive == true) {
                wake.acquire(6 * 60 * 60 * 1000L)
                mutableState.update { it.copy(finishing = true, paused = false, level = 0f) }
                main.post { updateNotification() }
                runBlocking { liveJob?.join() }
            }
            transcriptDone.set(true)
            if (summaryJob?.isActive == true) {
                wake.acquire(6 * 60 * 60 * 1000L)
                mutableState.update { it.copy(finishing = true, paused = false, level = 0f) }
                main.post { updateNotification() }
                runBlocking { summaryJob?.join() }
            }
            if (wake.isHeld) wake.release()
            val transcriptionError = state.value.transcriptionError
            mutableState.value = RecordingState(error = failure ?: transcriptionError)
            main.post { stopForeground(STOP_FOREGROUND_REMOVE); stopSelf() }
        }
    }

    override fun onDestroy() { stopping = true; scope.cancel(); super.onDestroy() }
}
