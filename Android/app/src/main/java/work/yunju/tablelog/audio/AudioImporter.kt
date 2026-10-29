package work.yunju.tablelog.audio

import android.content.Context
import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.net.Uri
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteOrder

/** Uses Android's codecs. Decodes incrementally and writes canonical PCM, never the full file in RAM. */
object AudioImporter {
    suspend fun decode(context: Context, uri: Uri, target: File, progress: (Int) -> Unit): Double {
        val extractor = MediaExtractor()
        var decoder: MediaCodec? = null
        try {
            context.contentResolver.openAssetFileDescriptor(uri, "r")?.use { fd ->
                if (fd.declaredLength >= 0) extractor.setDataSource(fd.fileDescriptor, fd.startOffset, fd.declaredLength)
                else extractor.setDataSource(fd.fileDescriptor)
            } ?: error("음성 파일을 열 수 없습니다.")
            val track = (0 until extractor.trackCount).firstOrNull { extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true }
                ?: error("지원하는 음성 트랙이 없습니다.")
            extractor.selectTrack(track)
            val format = extractor.getTrackFormat(track)
            val mime = format.getString(MediaFormat.KEY_MIME)!!
            val duration = if (format.containsKey(MediaFormat.KEY_DURATION)) format.getLong(MediaFormat.KEY_DURATION) else 0L
            format.setInteger(MediaFormat.KEY_PCM_ENCODING, AudioFormat.ENCODING_PCM_16BIT)
            val codec = MediaCodec.createDecoderByType(mime); decoder = codec
            codec.configure(format, null, null, 0); codec.start()
            var rate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            var channels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
            var resampler = PcmResampler(rate)
            var bytes = 0L; var ended = false; var done = false
            var lastPercent = -1
            val info = MediaCodec.BufferInfo()
            RandomAccessFile(target, "rw").use { output ->
                output.setLength(0); output.write(WavFile.header(0))
                try {
                    while (!done) {
                        currentCoroutineContext().ensureActive()
                        if (!ended) {
                            val index = codec.dequeueInputBuffer(10_000)
                            if (index >= 0) {
                                val buffer = codec.getInputBuffer(index)!!
                                val n = extractor.readSampleData(buffer, 0)
                                if (n < 0) { codec.queueInputBuffer(index, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM); ended = true }
                                else { codec.queueInputBuffer(index, 0, n, extractor.sampleTime, 0); extractor.advance() }
                            }
                        }
                        val index = codec.dequeueOutputBuffer(info, 10_000)
                        if (index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                            val changed = codec.outputFormat
                            val nextRate = changed.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                            require(bytes == 0L || nextRate == rate) { "도중에 샘플레이트가 바뀌는 파일은 지원하지 않습니다." }
                            rate = nextRate; channels = changed.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                            require(channels in 1..8)
                            if (changed.containsKey(MediaFormat.KEY_PCM_ENCODING)) require(changed.getInteger(MediaFormat.KEY_PCM_ENCODING) == AudioFormat.ENCODING_PCM_16BIT) { "이 기기의 음성 디코더 형식을 지원하지 않습니다." }
                            if (bytes == 0L) resampler = PcmResampler(rate)
                        } else if (index >= 0) {
                            try {
                                val buffer = codec.getOutputBuffer(index)!!.order(ByteOrder.LITTLE_ENDIAN)
                                buffer.position(info.offset); buffer.limit(info.offset + info.size)
                                val pcm = java.io.ByteArrayOutputStream()
                                while (buffer.remaining() >= channels * 2) {
                                    var sum = 0
                                    repeat(channels) { sum += buffer.short.toInt() }
                                    resampler.accept(sum / channels) { sample -> pcm.write(sample and 255); pcm.write((sample shr 8) and 255) }
                                }
                                val chunk = pcm.toByteArray()
                                check(bytes + chunk.size < 0xfffffff0L) { "변환할 수 있는 녹음 길이를 초과했습니다." }
                                output.write(chunk); bytes += chunk.size
                                if (duration > 0) {
                                    val percent = (info.presentationTimeUs * 100 / duration).toInt().coerceIn(0, 100)
                                    if (percent != lastPercent) { progress(percent); lastPercent = percent }
                                }
                                done = info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                            } finally { codec.releaseOutputBuffer(index, false) }
                        }
                    }
                    require(bytes > 0) { "음성 파일이 비어 있습니다." }
                } finally { output.seek(0); output.write(WavFile.header(bytes)); output.fd.sync() }
            }
            return bytes.toDouble() / WavFile.BYTES_PER_SECOND
        } finally { runCatching { decoder?.stop() }; decoder?.release(); extractor.release() }
    }
}

/** Carries interpolation position across codec buffers, so duration never resets at a boundary. */
class PcmResampler(private val sourceRate: Int) {
    init { require(sourceRate in 8000..192000) }
    private var index = 0L
    private var next = 0L
    private var previous = 0
    fun accept(sample: Int, emit: (Int) -> Unit) {
        val current = index * WavFile.SAMPLE_RATE
        while (next <= current) {
            val fraction = if (index == 0L) 1.0 else (next - (index - 1) * WavFile.SAMPLE_RATE).toDouble() / WavFile.SAMPLE_RATE
            emit((previous + (sample - previous) * fraction).toInt().coerceIn(-32768, 32767))
            next += sourceRate
        }
        previous = sample; index++
    }
}
