package `in`.droponevedimka.dropo

import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URI
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

internal class AndroidUpdateCancelled : IOException("Загрузка обновления отменена.")
internal class AndroidUpdateDownloadFailure(message: String) : IOException(message)

/** Bounded, cancellable streaming; never forwards credentials or opens an external browser. */
internal class AndroidUpdateDownload(
    private val cancelled: AtomicBoolean,
    private val connectionFactory: (String) -> HttpURLConnection = {
        URI(it).toURL().openConnection() as HttpURLConnection
    },
    private val trustedHop: (String) -> Boolean = AndroidUpdatePolicy::isTrustedDownloadHop,
) {
    private val active = AtomicReference<HttpURLConnection?>()
    private val deadline = System.nanoTime() + 15L * 60 * 1_000_000_000

    fun cancel() {
        cancelled.set(true)
        active.getAndSet(null)?.disconnect()
    }

    fun checkCancelled() {
        if (cancelled.get() || Thread.currentThread().isInterrupted) throw AndroidUpdateCancelled()
        if (System.nanoTime() > deadline) throw AndroidUpdateDownloadFailure("Время загрузки истекло. Повторите обновление.")
    }

    fun checksum(descriptor: AndroidUpdateDescriptor): String =
        withResponse(descriptor.checksumUrl) { connection ->
            val bytes = boundedRead(connection.inputStream, AndroidUpdatePolicy.MAX_CHECKSUM_BYTES.toLong())
            AndroidUpdatePolicy.parseChecksum(bytes.toString(Charsets.UTF_8), descriptor.assetName)
        }

    fun download(
        descriptor: AndroidUpdateDescriptor,
        destination: File,
        progress: (Long, Long) -> Unit,
    ) {
        withResponse(descriptor.downloadUrl) { connection ->
            val announced = connection.contentLengthLong
            require(announced == -1L || announced == descriptor.size) { "Размер APK на сервере изменился." }
            connection.inputStream.buffered().use { input ->
                destination.outputStream().buffered().use { output ->
                    copyExact(input, descriptor.size, { output.write(it, 0, it.size) }, progress)
                }
            }
        }
    }

    internal fun copyExact(
        input: InputStream,
        expected: Long,
        write: (ByteArray) -> Unit,
        progress: (Long, Long) -> Unit,
    ) {
        require(expected in 1..AndroidUpdatePolicy.MAX_APK_BYTES) { "Недопустимый размер APK." }
        var received = 0L
        var lastProgress = 0L
        val buffer = ByteArray(64 * 1024)
        progress(0, expected)
        while (true) {
            checkCancelled()
            val count = input.read(buffer)
            if (count < 0) break
            received += count
            require(received <= expected) { "Загруженный APK превышает ожидаемый размер." }
            write(buffer.copyOf(count))
            val now = System.nanoTime()
            if (received == expected || now - lastProgress > 200_000_000) {
                progress(received, expected)
                lastProgress = now
            }
        }
        require(received == expected) { "APK загружен не полностью. Повторите обновление." }
        checkCancelled()
    }

    private fun boundedRead(input: InputStream, maximum: Long): ByteArray {
        val bytes = ByteArrayOutputStream()
        input.use {
            val buffer = ByteArray(512)
            while (true) {
                checkCancelled()
                val count = it.read(buffer)
                if (count < 0) break
                require(bytes.size().toLong() + count <= maximum) { "Файл SHA-256 превышает допустимый размер." }
                bytes.write(buffer, 0, count)
            }
        }
        return bytes.toByteArray()
    }

    private fun <T> withResponse(initial: String, action: (HttpURLConnection) -> T): T {
        var current = initial
        repeat(6) { attempt ->
            checkCancelled()
            require(trustedHop(current)) { "Небезопасное перенаправление загрузки отклонено." }
            val connection = connectionFactory(current)
            active.set(connection)
            try {
                // Cancellation may arrive while the connection factory runs.
                checkCancelled()
                connection.instanceFollowRedirects = false
                connection.connectTimeout = 15000
                connection.readTimeout = 30000
                connection.setRequestProperty("User-Agent", "Dropo-Android-Updater")
                connection.setRequestProperty("Accept-Encoding", "identity")
                checkCancelled()
                val status = connection.responseCode
                if (status in setOf(301, 302, 303, 307, 308)) {
                    require(attempt < 5) { "Слишком много перенаправлений при загрузке APK." }
                    val location = connection.getHeaderField("Location")
                        ?: throw AndroidUpdateDownloadFailure("Сервер не сообщил адрес APK.")
                    current = URI(current).resolve(location).toString()
                } else {
                    if (status != 200) throw AndroidUpdateDownloadFailure("GitHub не отдал файл обновления (HTTP $status). Повторите позже.")
                    checkCancelled()
                    return action(connection)
                }
            } finally {
                active.compareAndSet(connection, null)
                connection.disconnect()
            }
        }
        throw AndroidUpdateDownloadFailure("Не удалось получить файл обновления.")
    }
}
