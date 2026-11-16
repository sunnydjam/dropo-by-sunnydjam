package `in`.droponevedimka.dropo

import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.File

/** One private cache slot, bound to the release metadata and freshly fetched SHA-256. */
internal class AndroidUpdateResumeStore(
    private val partial: File,
    private val descriptor: AndroidUpdateDescriptor,
    private val checksum: String,
    private val clockMillis: () -> Long = System::currentTimeMillis,
) {
    data class Checkpoint(val bytes: Long, val validator: String?)

    private val metadata = File(partial.parentFile, "${partial.name}.resume")
    private val temporary = File(partial.parentFile, "${partial.name}.resume.tmp")

    fun prepare(): Checkpoint {
        require(checksum.matches(Regex("[a-f0-9]{64}"))) { "Некорректная контрольная сумма APK." }
        val saved = runCatching {
            require(partial.isFile && metadata.isFile && metadata.length() in 1..MAX_METADATA_BYTES)
            require(clockMillis() - partial.lastModified() in 0..MAX_AGE_MILLIS)
            require(partial.length() in 1..descriptor.size)
            DataInputStream(metadata.inputStream().buffered()).use {
                require(it.readInt() == FORMAT)
                require(it.readUTF() == descriptor.version)
                require(it.readUTF() == descriptor.assetName)
                require(it.readUTF() == descriptor.downloadUrl)
                require(it.readLong() == descriptor.size)
                require(it.readUTF() == checksum)
                val validator = it.readUTF().takeIf(String::isNotEmpty)
                require(validator == null || strongETag(validator) == validator)
                require(it.read() == -1)
                Checkpoint(partial.length(), validator)
            }
        }.getOrNull()
        if (saved != null) return saved
        discard()
        return Checkpoint(0, null)
    }

    fun record(validator: String?) {
        DataOutputStream(temporary.outputStream().buffered()).use {
            it.writeInt(FORMAT)
            it.writeUTF(descriptor.version)
            it.writeUTF(descriptor.assetName)
            it.writeUTF(descriptor.downloadUrl)
            it.writeLong(descriptor.size)
            it.writeUTF(checksum)
            it.writeUTF(strongETag(validator).orEmpty())
        }
        require(!metadata.exists() || metadata.delete()) { "Не удалось обновить данные загрузки." }
        require(temporary.renameTo(metadata)) { "Не удалось сохранить данные загрузки." }
    }

    fun discard() {
        // Fixed private cache paths only. Never delete user-selected files or directories.
        for (file in listOf(partial, metadata, temporary)) {
            require(!file.exists() || (file.isFile && file.delete())) { "Не удалось очистить кэш обновления." }
        }
    }

    fun complete() {
        metadata.delete()
        temporary.delete()
    }

    companion object {
        private const val FORMAT = 1
        private const val MAX_METADATA_BYTES = 24L * 1024
        private const val MAX_AGE_MILLIS = 7L * 24 * 60 * 60 * 1000

        fun strongETag(value: String?): String? = value?.takeIf {
            it.length in 2..512 && it.startsWith('"') && it.endsWith('"') &&
                it.substring(1, it.lastIndex).all { c -> c.code in 0x21..0x7e && c != '"' }
        }
    }
}
