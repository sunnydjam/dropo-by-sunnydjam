package `in`.droponevedimka.dropo

import java.io.File
import java.net.URI
import java.security.MessageDigest
import java.util.concurrent.atomic.AtomicBoolean

/** Permission callbacks and installer handoff must obey the same bounded user request. */
internal class AndroidUpdateRequestFence(
    private val clock: () -> Long = System::nanoTime,
) {
    val cancelled = AtomicBoolean(false)
    private val deadline = clock() + AndroidUpdatePolicy.MAX_UPDATE_MILLIS * 1_000_000
    fun expired(): Boolean = clock() >= deadline
    fun canResume(): Boolean = !cancelled.get() && !expired()
}

/** Only the APK belonging to the installed package/channel may reach the installer. */
internal data class AndroidUpdateDescriptor(
    val version: String,
    val assetName: String,
    val downloadUrl: String,
    val size: Long,
) {
    val checksumUrl: String get() = "$downloadUrl.sha256"
}

internal object AndroidUpdatePolicy {
    const val MAX_UPDATE_MILLIS = 15L * 60 * 1000
    const val MAX_APK_BYTES = 384L * 1024 * 1024
    const val MAX_CHECKSUM_BYTES = 1024
    private const val REPOSITORY = "sunnydjam/dropo-by-sunnydjam"
    private val versionPattern = Regex("[0-9]{1,5}\\.[0-9]{1,5}\\.[0-9]{1,5}(-preview)?")
    private val digestPattern = Regex("[a-fA-F0-9]{64}")
    private val downloadHosts = setOf(
        "github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com",
    )

    fun validateDescriptor(value: AndroidUpdateDescriptor, installedPackage: String) {
        require(installedPackage == "in.droponevedimka.dropo" ||
            installedPackage == "in.droponevedimka.dropo.preview") { "Неизвестный пакет Dropo." }
        require(versionPattern.matches(value.version)) { "Некорректная версия обновления." }
        val preview = installedPackage.endsWith(".preview")
        require(value.version.endsWith("-preview") == preview) {
            "Обновление предназначено для другого канала Dropo."
        }
        val prefix = if (preview) "dropo-Android-Preview-" else "dropo-Android-"
        require(value.assetName in setOf("${prefix}universal.apk", "${prefix}arm64.apk")) {
            "Обновление предназначено для другого пакета Dropo."
        }
        require(value.size in 1..MAX_APK_BYTES) { "Недопустимый размер APK." }
        val tag = value.version.removeSuffix("-preview")
        require(value.downloadUrl ==
            "https://github.com/$REPOSITORY/releases/download/v$tag/${value.assetName}") {
            "Ссылка на обновление не принадлежит выпуску Dropo."
        }
    }

    fun isTrustedDownloadHop(value: String): Boolean = runCatching {
        val uri = URI(value)
        value.length <= 16384 && uri.scheme == "https" && uri.userInfo == null &&
            uri.fragment == null && (uri.port == -1 || uri.port == 443) &&
            uri.host?.lowercase() in downloadHosts
    }.getOrDefault(false)

    fun parseChecksum(text: String, assetName: String): String {
        require(text.toByteArray(Charsets.UTF_8).size <= MAX_CHECKSUM_BYTES) {
            "Некорректный файл SHA-256."
        }
        val lines = text.trim().lines()
        require(lines.size == 1) { "Некорректный файл SHA-256." }
        val fields = lines.single().trim().split(Regex("\\s+"), limit = 2)
        require(digestPattern.matches(fields[0])) { "Некорректная контрольная сумма APK." }
        if (fields.size > 1) {
            require(fields[1].removePrefix("*") == assetName) {
                "Контрольная сумма относится к другому файлу."
            }
        }
        return fields[0].lowercase()
    }

    fun sha256(file: File, checkCancelled: () -> Unit = {}): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().buffered().use { input ->
            val buffer = ByteArray(64 * 1024)
            while (true) {
                checkCancelled()
                val count = input.read(buffer)
                if (count < 0) break
                digest.update(buffer, 0, count)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it.toInt() and 0xff) }
    }

    fun validateArchive(
        descriptor: AndroidUpdateDescriptor,
        installedPackage: String,
        installedVersionCode: Long,
        installedSigners: Set<String>,
        archivePackage: String,
        archiveVersionName: String,
        archiveVersionCode: Long,
        archiveSigners: Set<String>,
        minimumSdk: Int,
        deviceSdk: Int,
        supportedAbis: Set<String>,
        archiveAbis: Set<String>,
    ) {
        require(archivePackage == installedPackage) { "APK предназначен для другого приложения." }
        require(archiveVersionName == descriptor.version && archiveVersionCode > installedVersionCode) {
            "Версия APK не соответствует обновлению или не новее установленной."
        }
        require(installedSigners.isNotEmpty() && installedSigners == archiveSigners) {
            "Подпись APK не совпадает с установленным Dropo. Обновление отменено."
        }
        require(minimumSdk <= deviceSdk) { "Обновление не поддерживает вашу версию Android." }
        require(archiveAbis.isNotEmpty() && archiveAbis.any { it in supportedAbis }) {
            "APK не поддерживает архитектуру вашего телефона."
        }
    }
}
