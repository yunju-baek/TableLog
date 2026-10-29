package work.yunju.tablelog.ai

import com.k2fsa.sherpa.onnx.*
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import work.yunju.tablelog.audio.WavFile
import work.yunju.tablelog.data.Utterance
import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** One serial native engine and a bounded VAD segment. The growing WAV is the backlog, not RAM. */
class LocalTranscriber(private val models: LocalModelStore) {
    suspend fun transcribe(file: File, progress: (Int) -> Unit): List<Utterance> {
        validateWave(file)
        val bytes = file.length() - WavFile.HEADER_SIZE
        val output = mutableListOf<Utterance>()
        follow(file, { bytes }, { true }, { output += it.copy(id = output.size + 1) }, { progress((it * 100 / bytes).toInt()) }, 20f)
        return output
    }

    /** Reads only committed PCM bytes. Final short frames are padded once, after recording ends. */
    suspend fun follow(file: File, available: () -> Long, finished: () -> Boolean,
                       onUtterance: (Utterance) -> Unit, onProgress: (Long) -> Unit, maxSpeechSeconds: Float = 10f) {
        models.verify()
        var recognizer: OfflineRecognizer? = null
        var vad: Vad? = null
        try {
            currentCoroutineContext().ensureActive()
            val spec = models.definition
            fun path(name: String) = File(models.directory, name).path
            val config = OfflineModelConfig(tokens = path(spec.tokens), numThreads = 2, provider = "cpu", debug = false)
            if (spec.engine == "whisper") config.whisper = OfflineWhisperModelConfig(
                encoder = path(spec.encoder), decoder = path(spec.decoder), language = models.language.takeUnless { it == "auto" }.orEmpty(), task = "transcribe")
            else config.senseVoice = OfflineSenseVoiceModelConfig(path(spec.model), language = models.language, useInverseTextNormalization = true)
            val engine = OfflineRecognizer(config = OfflineRecognizerConfig(modelConfig = config))
            recognizer = engine
            val detector = Vad(config = VadModelConfig(sileroVadModelConfig = SileroVadModelConfig(
                model = path("silero_vad.onnx"), minSilenceDuration = 0.5f, minSpeechDuration = 0.25f, maxSpeechDuration = maxSpeechSeconds,
            ), numThreads = 1, provider = "cpu", debug = false))
            vad = detector
            suspend fun drain() {
                while (!detector.empty()) {
                    currentCoroutineContext().ensureActive()
                    val segment = detector.front(); detector.pop()
                    check(segment.samples.size <= 25 * WavFile.SAMPLE_RATE) { "음성 구간이 처리 한도를 초과했습니다." }
                    val stream = engine.createStream()
                    try {
                        stream.acceptWaveform(segment.samples, WavFile.SAMPLE_RATE); engine.decode(stream)
                        currentCoroutineContext().ensureActive()
                        val text = engine.getResult(stream).text.trim()
                        if (text.isNotBlank()) {
                            val duration = available().toDouble() / WavFile.BYTES_PER_SECOND
                            val start = (segment.start.toDouble() / WavFile.SAMPLE_RATE).coerceIn(0.0, duration)
                            val end = ((segment.start + segment.samples.size).toDouble() / WavFile.SAMPLE_RATE).coerceIn(start, duration)
                            onUtterance(Utterance(0, "화자 미지정", start, end, text))
                        }
                    } finally { stream.release() }
                }
            }
            RandomAccessFile(file, "r").use { input ->
                input.seek(WavFile.HEADER_SIZE.toLong())
                val buffer = ByteArray(1024)
                var read = 0L
                var reported = -1L
                while (true) {
                    currentCoroutineContext().ensureActive()
                    // Acquire the completion flag before the byte count to include the final write.
                    val done = finished()
                    val remaining = available() - read
                    if (remaining < buffer.size && !done) { delay(40); continue }
                    if (remaining <= 0 && done) break
                    val n = minOf(buffer.size.toLong(), remaining).toInt()
                    require(n % 2 == 0)
                    input.readFully(buffer, 0, n)
                    val pcm = ByteBuffer.wrap(buffer, 0, n).order(ByteOrder.LITTLE_ENDIAN)
                    val samples = FloatArray(512)
                    for (i in 0 until n / 2) samples[i] = pcm.short / 32768f
                    detector.acceptWaveform(samples); drain(); read += n
                    if (read - reported >= WavFile.BYTES_PER_SECOND / 2 || done && read == available()) {
                        onProgress(read); reported = read
                    }
                }
                detector.flush(); drain(); onProgress(read)
            }
        } finally { vad?.release(); recognizer?.release() }
    }

    companion object {
        fun validateWave(file: File): Double {
            require(file.length() > WavFile.HEADER_SIZE && (file.length() - WavFile.HEADER_SIZE) % 2 == 0L) { "유효한 녹음 파일이 아닙니다." }
            val header = ByteArray(WavFile.HEADER_SIZE)
            RandomAccessFile(file, "r").use { it.readFully(header) }
            require(header.contentEquals(WavFile.header(file.length() - WavFile.HEADER_SIZE))) { "16kHz mono PCM WAV 녹음만 전사할 수 있습니다." }
            return (file.length() - WavFile.HEADER_SIZE).toDouble() / WavFile.BYTES_PER_SECOND
        }
    }
}
