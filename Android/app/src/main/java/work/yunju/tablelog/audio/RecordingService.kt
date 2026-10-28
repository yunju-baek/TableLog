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
import kotlinx.coroutines.flow.MutableStateFlow
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
)

class RecordingService : Service() {
    companion object {
        const val START = "work.yunju.tablelog.START"
        const val PAUSE = "work.yunju.tablelog.PAUSE"
        const val RESUME = "work.yunju.tablelog.RESUME"
        const val STOP = "work.yunju.tablelog.STOP"
        private val mutableState = MutableStateFlow(RecordingState())
        val state = mutableState.asStateFlow()
    }
    @Volatile private var stopping = false
    @Volatile private var paused = false
    private var worker: Thread? = null
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
                    val notification = notification(false)
                    if (Build.VERSION.SDK_INT >= 30) startForeground(1, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
                    else startForeground(1, notification)
                    stopping = false; paused = false
                    val title = intent.getStringExtra("title")?.trim()?.take(500).orEmpty().ifBlank { "새 회의" }
                    worker = thread(name = "TableLog recorder") { record(title) }
                } catch (e: Exception) {
                    mutableState.value = RecordingState(error = "녹음을 시작할 수 없습니다. ${e.message.orEmpty()}")
                    stopSelf()
                }
            }
            PAUSE -> { paused = true; updateNotification() }
            RESUME -> { paused = false; updateNotification() }
            STOP -> { stopping = true }
            else -> if (worker == null) stopSelf()
        }
        return START_NOT_STICKY
    }

    private fun notification(isPaused: Boolean): Notification {
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        fun action(action: String, code: Int) = PendingIntent.getService(this, code,
            Intent(this, RecordingService::class.java).setAction(action), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
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
    private fun record(title: String) {
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
            meeting = repository.save(Meeting(title = title, audioName = "recording.wav", status = "recording"))
            file = RandomAccessFile(repository.audioFile(meeting)!!, "rw")
            file.write(WavFile.header(0))
            mutableState.value = RecordingState(meetingId = meeting.id)
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
                        if (wake.isHeld) wake.release()
                        mutableState.value = mutableState.value.copy(paused = true, level = 0f)
                    }
                    Thread.sleep(50)
                    continue
                }
                if (wasPaused) {
                    wake.acquire(10 * 60 * 1000L); recorder.startRecording(); wasPaused = false
                    checkpoint("recording")
                    mutableState.value = mutableState.value.copy(paused = false)
                }
                val read = recorder.read(buffer, 0, buffer.size, AudioRecord.READ_BLOCKING)
                check(read >= 0) { "마이크 연결이 끊어졌습니다. (오류 $read)" }
                if (read == 0) { Thread.sleep(20); continue }
                check(bytes + read < 0xfffffff0L) { "파일 크기 한도에 도달해 녹음을 저장합니다." }
                file.write(buffer, 0, read); bytes += read
                var peak = 0
                for (i in 0 until read - 1 step 2) {
                    val value = ((buffer[i].toInt() and 255) or (buffer[i + 1].toInt() shl 8)).toShort().toInt()
                    peak = maxOf(peak, abs(value))
                }
                mutableState.value = RecordingState(meeting.id, false, bytes.toDouble() / WavFile.BYTES_PER_SECOND, peak / 32768f)
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
            if (wake.isHeld) wake.release()
            mutableState.value = RecordingState(error = failure)
            main.post { stopForeground(STOP_FOREGROUND_REMOVE); stopSelf() }
        }
    }

    override fun onDestroy() { stopping = true; super.onDestroy() }
}
