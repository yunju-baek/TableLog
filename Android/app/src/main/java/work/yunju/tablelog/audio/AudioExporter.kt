package work.yunju.tablelog.audio

import android.content.Context
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import android.net.Uri
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import java.io.File
import java.io.RandomAccessFile

object AudioExporter {
    suspend fun m4a(context: Context, source: File, destination: Uri, progress: (Int) -> Unit) {
        work.yunju.tablelog.ai.LocalTranscriber.validateWave(source)
        context.contentResolver.openFileDescriptor(destination, "rw")?.use { fd ->
            val codec = MediaCodec.createEncoderByType("audio/mp4a-latm")
            var muxer: MediaMuxer? = null; var started = false
            try {
                val format = MediaFormat.createAudioFormat("audio/mp4a-latm", WavFile.SAMPLE_RATE, 1).apply {
                    setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
                    setInteger(MediaFormat.KEY_BIT_RATE, 96000)
                    setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 8192)
                }
                codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE); codec.start()
                val writer = MediaMuxer(fd.fileDescriptor, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4); muxer = writer
                var track = -1; var inputEnded = false; var outputEnded = false; var bytes = 0L
                val size = source.length() - 44
                val info = MediaCodec.BufferInfo(); val buffer = ByteArray(8192)
                RandomAccessFile(source, "r").use { audio ->
                    audio.seek(44)
                    while (!outputEnded) {
                        currentCoroutineContext().ensureActive()
                        if (!inputEnded) {
                            val index = codec.dequeueInputBuffer(10_000)
                            if (index >= 0) {
                                val target = codec.getInputBuffer(index)!!
                                val n = audio.read(buffer, 0, minOf(buffer.size, target.remaining()))
                                val time = bytes * 1_000_000 / WavFile.BYTES_PER_SECOND
                                if (n < 0) { codec.queueInputBuffer(index, 0, 0, time, MediaCodec.BUFFER_FLAG_END_OF_STREAM); inputEnded = true }
                                else { target.put(buffer, 0, n); codec.queueInputBuffer(index, 0, n, time, 0); bytes += n }
                            }
                        }
                        val index = codec.dequeueOutputBuffer(info, 10_000)
                        if (index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                            track = writer.addTrack(codec.outputFormat); writer.start(); started = true
                        } else if (index >= 0) {
                            try {
                                if (info.size > 0 && info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0) {
                                    check(started)
                                    val data = codec.getOutputBuffer(index)!!; data.position(info.offset); data.limit(info.offset + info.size)
                                    writer.writeSampleData(track, data, info)
                                }
                                outputEnded = info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                            } finally { codec.releaseOutputBuffer(index, false) }
                        }
                        progress((bytes * 100 / size).toInt())
                    }
                }
            } finally { runCatching { codec.stop() }; codec.release(); if (started) runCatching { muxer?.stop() }; muxer?.release() }
        } ?: error("M4A 파일을 저장할 수 없습니다.")
    }
}
