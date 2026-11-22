package `in`.droponevedimka.dropo

import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
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
    @Volatile var keepsPartialOnCancellation = false
        private set

    fun cancel(keepPartial: Boolean = false) {
        keepsPartialOnCancellation = keepPartial
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
        checksum: String,
        progress: (Long, Long) -> Unit,
    ) {
        val store = AndroidUpdateResumeStore(destination, descriptor, checksum)
        var checkpoint = store.prepare()
        try {
            checkCancelled()
            if (checkpoint.bytes == descriptor.size) {
                // The caller still verifies the complete digest and installed-package signer.
                progress(descriptor.size, descriptor.size)
                return
            }
            repeat(2) {
                val headers = if (checkpoint.bytes > 0) buildMap {
                    put("Range", "bytes=${checkpoint.bytes}-")
                    checkpoint.validator?.let { put("If-Range", it) }
                } else emptyMap()
                val complete = withResponse(descriptor.downloadUrl, headers, setOf(200, 206, 416)) { connection ->
                    if (connection.responseCode == 416 && checkpoint.bytes > 0) {
                        // Some mirrors stop supporting ranges. Retry once from byte zero.
                        store.discard()
                        checkpoint = AndroidUpdateResumeStore.Checkpoint(0, null)
                        return@withResponse false
                    }
                    val encoding = connection.getHeaderField("Content-Encoding")
                    require(encoding.isNullOrBlank() || encoding.equals("identity", true)) {
                        "Сервер изменил кодирование APK. Повторите загрузку."
                    }
                    val offset = when (connection.responseCode) {
                        200 -> 0L // Range ignored or If-Range no longer matches: replace, never append.
                        206 -> {
                            require(checkpoint.bytes > 0) { "Неожиданный частичный ответ APK." }
                            validateRange(connection.getHeaderField("Content-Range"), checkpoint.bytes, descriptor.size)
                            val receivedValidator = AndroidUpdateResumeStore.strongETag(connection.getHeaderField("ETag"))
                            require(checkpoint.validator == null || receivedValidator == null || receivedValidator == checkpoint.validator) {
                                "APK на сервере изменился. Повторите загрузку."
                            }
                            checkpoint.bytes
                        }
                        else -> throw AndroidUpdateDownloadFailure("Сервер не поддерживает загрузку APK. Повторите позже.")
                    }
                    val announced = connection.contentLengthLong
                    require(announced == -1L || announced == descriptor.size - offset) { "Размер APK на сервере изменился." }
                    connection.inputStream.buffered().use { input ->
                        FileOutputStream(destination, offset > 0).buffered().use { output ->
                            store.record(AndroidUpdateResumeStore.strongETag(connection.getHeaderField("ETag"))
                                ?: checkpoint.validator.takeIf { offset > 0 })
                            copyExactFrom(input, descriptor.size, offset, { output.write(it, 0, it.size) }, progress)
                        }
                    }
                    true
                }
                if (complete) return
            }
            throw AndroidUpdateDownloadFailure("Не удалось загрузить APK. Повторите обновление.")
        } catch (error: Throwable) {
            // Network failures keep a bound partial download. Malformed responses, integrity
            // errors and explicit cancellation start clean on the next user request.
            if (error !is IOException || (cancelled.get() && !keepsPartialOnCancellation)) store.discard()
            throw error
        }
    }

    private fun validateRange(value: String?, offset: Long, total: Long) {
        val match = value?.let { Regex("bytes ([0-9]+)-([0-9]+)/([0-9]+)").matchEntire(it) }
        require(match != null && match.groupValues[1].toLongOrNull() == offset &&
            match.groupValues[2].toLongOrNull() == total - 1 && match.groupValues[3].toLongOrNull() == total) {
            "Некорректный диапазон APK. Повторите загрузку."
        }
    }

    internal fun copyExact(
        input: InputStream,
        expected: Long,
        write: (ByteArray) -> Unit,
        progress: (Long, Long) -> Unit,
    ) = copyExactFrom(input, expected, 0, write, progress)

    private fun copyExactFrom(
        input: InputStream,
        expected: Long,
        offset: Long,
        write: (ByteArray) -> Unit,
        progress: (Long, Long) -> Unit,
    ) {
        require(expected in 1..AndroidUpdatePolicy.MAX_APK_BYTES) { "Недопустимый размер APK." }
        require(offset in 0 until expected) { "Некорректное смещение APK." }
        var received = offset
        var lastProgress = 0L
        val buffer = ByteArray(64 * 1024)
        progress(offset, expected)
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
        if (received != expected) throw AndroidUpdateDownloadFailure("APK загружен не полностью. Нажмите «Обновить», чтобы продолжить загрузку.")
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

    private fun <T> withResponse(
        initial: String,
        headers: Map<String, String> = emptyMap(),
        acceptedStatuses: Set<Int> = setOf(200),
        action: (HttpURLConnection) -> T,
    ): T {
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
                headers.forEach(connection::setRequestProperty)
                checkCancelled()
                val status = connection.responseCode
                if (status in setOf(301, 302, 303, 307, 308)) {
                    require(attempt < 5) { "Слишком много перенаправлений при загрузке APK." }
                    val location = connection.getHeaderField("Location")
                        ?: throw AndroidUpdateDownloadFailure("Сервер не сообщил адрес APK.")
                    current = URI(current).resolve(location).toString()
                } else {
                    if (status !in acceptedStatuses) throw AndroidUpdateDownloadFailure("GitHub не отдал файл обновления (HTTP $status). Повторите позже.")
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
