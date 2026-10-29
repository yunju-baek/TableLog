package work.yunju.tablelog.ai

import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import work.yunju.tablelog.audio.WavFile
import work.yunju.tablelog.data.Utterance
import java.io.File
import java.io.RandomAccessFile
import kotlin.math.abs

/** Sends bounded WAV ranges, normally at a pause after 5 seconds, at most every 25 seconds. */
class ServerLiveTranscriber(private val client: AIClient) {
    suspend fun follow(file: File, available: () -> Long, finished: () -> Boolean,
                       onUtterance: (Utterance) -> Unit, onProgress: (Long) -> Unit) {
        RandomAccessFile(file, "r").use { input ->
            input.seek(WavFile.HEADER_SIZE.toLong())
            val frame = ByteArray(3200)
            var read = 0L; var start = 0L; var quiet = 0L; var voiced = false
            suspend fun submit() {
                currentCoroutineContext().ensureActive()
                if (voiced && read > start) client.transcribeRange(file, start, read - start).forEach(onUtterance)
                start = read; quiet = 0; voiced = false; onProgress(read)
            }
            while (true) {
                currentCoroutineContext().ensureActive()
                val done = finished(); val left = available() - read
                if (left < frame.size && !done) { delay(50); continue }
                if (left <= 0 && done) break
                val n = minOf(frame.size.toLong(), left).toInt()
                input.readFully(frame, 0, n)
                var energy = 0.0
                for (i in 0 until n - 1 step 2) {
                    val sample = ((frame[i].toInt() and 255) or (frame[i + 1].toInt() shl 8)).toShort().toInt()
                    energy += abs(sample)
                }
                val speech = energy / (n / 2).coerceAtLeast(1) > 100
                voiced = voiced || speech
                quiet = if (speech) 0 else quiet + n
                read += n
                if (read - start >= 25L * WavFile.BYTES_PER_SECOND ||
                    read - start >= 5L * WavFile.BYTES_PER_SECOND && quiet >= WavFile.BYTES_PER_SECOND / 2) submit()
            }
            submit()
        }
    }
}
