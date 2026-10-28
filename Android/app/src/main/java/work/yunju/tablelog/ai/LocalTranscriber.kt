package work.yunju.tablelog.ai

import com.k2fsa.sherpa.onnx.*
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import work.yunju.tablelog.audio.WavFile
import work.yunju.tablelog.data.Utterance
import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Serial CPU inference; holds one bounded speech segment, never the complete recording. */
class LocalTranscriber(private val models: LocalModelStore) {
    suspend fun transcribe(file: File, progress: (Int) -> Unit): List<Utterance> {
        models.verify()
        val duration = validateWave(file)
        var recognizer: OfflineRecognizer? = null
        var vad: Vad? = null
        try {
            currentCoroutineContext().ensureActive()
            val engine = OfflineRecognizer(config = OfflineRecognizerConfig(modelConfig = OfflineModelConfig(
                senseVoice = OfflineSenseVoiceModelConfig(File(models.directory, "model.int8.onnx").path, language = "ko", useInverseTextNormalization = true),
                tokens = File(models.directory, "tokens.txt").path, numThreads = 2, provider = "cpu", debug = false,
            )))
            recognizer = engine
            val detector = Vad(config = VadModelConfig(sileroVadModelConfig = SileroVadModelConfig(
                model = File(models.directory, "silero_vad.onnx").path, minSilenceDuration = 0.5f,
                minSpeechDuration = 0.25f, maxSpeechDuration = 20f,
            ), numThreads = 1, provider = "cpu", debug = false))
            vad = detector
            val output = mutableListOf<Utterance>()
            suspend fun drain() {
                while (!detector.empty()) {
                    currentCoroutineContext().ensureActive()
                    val segment = detector.front()
                    detector.pop()
                    check(segment.samples.size <= 25 * WavFile.SAMPLE_RATE) { "음성 구간이 처리 한도를 초과했습니다." }
                    val stream = engine.createStream()
                    try {
                        stream.acceptWaveform(segment.samples, WavFile.SAMPLE_RATE)
                        engine.decode(stream)
                        currentCoroutineContext().ensureActive()
                        val text = engine.getResult(stream).text.trim()
                        if (text.isNotBlank()) {
                            val start = (segment.start.toDouble() / WavFile.SAMPLE_RATE).coerceIn(0.0, duration)
                            val end = ((segment.start + segment.samples.size).toDouble() / WavFile.SAMPLE_RATE).coerceIn(start, duration)
                            output += Utterance(output.size + 1, "화자 미지정", start, end, text)
                        }
                    } finally { stream.release() }
                }
            }
            RandomAccessFile(file, "r").use { input ->
                input.seek(WavFile.HEADER_SIZE.toLong())
                val buffer = ByteArray(1024)
                val dataBytes = file.length() - WavFile.HEADER_SIZE
                var read = 0L
                var lastPercent = -1
                while (read < dataBytes) {
                    currentCoroutineContext().ensureActive()
                    val n = minOf(buffer.size.toLong(), dataBytes - read).toInt()
                    input.readFully(buffer, 0, n)
                    // Zero-pad only the final VAD frame; times are clipped to the real PCM duration.
                    val pcm = ByteBuffer.wrap(buffer, 0, n).order(ByteOrder.LITTLE_ENDIAN)
                    val samples = FloatArray(512)
                    for (i in 0 until n / 2) samples[i] = pcm.short / 32768f
                    detector.acceptWaveform(samples)
                    drain()
                    read += n
                    val percent = (read * 100 / dataBytes).toInt()
                    if (percent != lastPercent) { progress(percent); lastPercent = percent }
                }
            }
            detector.flush(); drain()
            return output
        } finally {
            vad?.release()
            recognizer?.release()
        }
    }

    companion object {
        fun validateWave(file: File): Double {
            require(file.length() > WavFile.HEADER_SIZE && (file.length() - WavFile.HEADER_SIZE) % 2 == 0L) { "유효한 녹음 파일이 아닙니다." }
            val header = ByteArray(WavFile.HEADER_SIZE)
            RandomAccessFile(file, "r").use { it.readFully(header) }
            // Only TableLog's own canonical mono PCM16/16kHz files are admitted to native code.
            require(header.contentEquals(WavFile.header(file.length() - WavFile.HEADER_SIZE))) { "16kHz mono PCM WAV 녹음만 전사할 수 있습니다." }
            return (file.length() - WavFile.HEADER_SIZE).toDouble() / WavFile.BYTES_PER_SECOND
        }
    }
}
