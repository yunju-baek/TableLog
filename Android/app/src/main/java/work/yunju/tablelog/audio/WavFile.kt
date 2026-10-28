package work.yunju.tablelog.audio

import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** PCM 16 kHz, mono, signed 16-bit. A header can be rebuilt after process death. */
object WavFile {
    const val SAMPLE_RATE = 16000
    const val BYTES_PER_SECOND = SAMPLE_RATE * 2
    const val HEADER_SIZE = 44
    fun header(dataSize: Long): ByteArray {
        require(dataSize in 0..0xfffffff0L)
        return ByteBuffer.allocate(HEADER_SIZE).order(ByteOrder.LITTLE_ENDIAN).apply {
            put("RIFF".toByteArray()); putInt((36 + dataSize).toInt()); put("WAVEfmt ".toByteArray())
            putInt(16); putShort(1); putShort(1); putInt(SAMPLE_RATE); putInt(BYTES_PER_SECOND)
            putShort(2); putShort(16); put("data".toByteArray()); putInt(dataSize.toInt())
        }.array()
    }
    fun repair(file: File): Double {
        RandomAccessFile(file, "rw").use { stream ->
            require(stream.length() >= HEADER_SIZE) { "녹음 파일에 오디오 데이터가 없습니다." }
            val data = (stream.length() - HEADER_SIZE) / 2 * 2
            stream.setLength(HEADER_SIZE + data)
            stream.seek(0); stream.write(header(data)); stream.fd.sync()
            return data.toDouble() / BYTES_PER_SECOND
        }
    }
}
