package `in`.droponevedimka.dropo

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import androidx.core.content.FileProvider
import dropoandroid.Dropoandroid
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.File
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import java.security.MessageDigest
import java.util.concurrent.Executors
import java.util.concurrent.Future
import java.util.zip.ZipFile

/** User-requested updates only. Download/verification never stop or mutate the VPN session. */
internal class AndroidApkUpdater(private val activity: Activity) {
    private val executor = Executors.newSingleThreadExecutor()
    private val handler = Handler(Looper.getMainLooper())
    private var pending: Request? = null
    private var closed = false
    private var nextPermissionCode = FIRST_INSTALL_PERMISSION_CODE

    private class Request(val result: MethodChannel.Result, val permissionCode: Int) {
        val fence = AndroidUpdateRequestFence(SystemClock::elapsedRealtimeNanos)
        val cancelled = fence.cancelled
        val download = AndroidUpdateDownload(cancelled)
        var task: Future<*>? = null
        var descriptor: AndroidUpdateDescriptor? = null
        var verifiedFile: File? = null
        var awaitingPermission = false
        var leftForPermission = false
        var watchdog: Runnable? = null
    }

    fun start(result: MethodChannel.Result) {
        if (BuildConfig.PLAY_DISTRIBUTION) {
            result.success(json(false, "Эта версия обновляется только через Google Play."))
            return
        }
        if (closed || pending != null) {
            result.success(json(false, "Обновление уже выполняется. Дождитесь завершения или отмените загрузку."))
            return
        }
        val request = Request(result, nextPermissionCode)
        nextPermissionCode = if (nextPermissionCode == LAST_INSTALL_PERMISSION_CODE) {
            FIRST_INSTALL_PERMISSION_CODE
        } else nextPermissionCode + 1
        pending = request
        request.watchdog = Runnable { expire(request) }.also {
            handler.postDelayed(it, AndroidUpdatePolicy.MAX_UPDATE_MILLIS)
        }
        stage(request, "checking")
        request.task = executor.submit {
            try {
                // Resolve again inside the app: Flutter cannot supply arbitrary URLs or files.
                val metadata = JSONObject(Dropoandroid.call("CheckForUpdates", "[]"))
                request.download.checkCancelled()
                require(metadata.optBoolean("success")) {
                    "Не удалось проверить новую версию. Повторите проверку обновлений."
                }
                require(metadata.optBoolean("hasUpdate")) { "Установлена актуальная версия Dropo." }
                val descriptor = AndroidUpdateDescriptor(
                    metadata.optString("latestVersion"), metadata.optString("assetName"),
                    metadata.optString("downloadURL"), metadata.optLong("fileSize"),
                )
                AndroidUpdatePolicy.validateDescriptor(descriptor, activity.packageName)
                request.descriptor = descriptor
                val directory = File(activity.cacheDir, "updates")
                require(directory.isDirectory || directory.mkdirs()) { "Не удалось создать папку обновления." }
                val completed = File(directory, "dropo-update.apk")
                val partial = File(directory, "dropo-update.part")
                val checksum = request.download.checksum(descriptor)
                val reusable = completed.isFile && completed.length() == descriptor.size &&
                    AndroidUpdatePolicy.sha256(completed, request.download::checkCancelled) == checksum
                try {
                    if (!reusable) {
                        require(directory.usableSpace >= descriptor.size + 16L * 1024 * 1024) {
                            "Не хватает места для обновления. Освободите минимум ${descriptor.size / 1048576 + 16} МБ."
                        }
                        stage(request, "downloading")
                        request.download.download(descriptor, partial) { downloaded, total ->
                            event(request, "update-progress", mapOf(
                                "downloaded" to downloaded, "total" to total,
                                "percent" to downloaded.toDouble() * 100 / total,
                            ))
                        }
                        stage(request, "verifying")
                        require(AndroidUpdatePolicy.sha256(partial, request.download::checkCancelled) == checksum) {
                            "SHA-256 APK не совпадает. Файл не будет установлен; повторите загрузку."
                        }
                        validateArchive(descriptor, partial)
                        request.download.checkCancelled()
                        require(!completed.exists() || completed.delete()) { "Не удалось заменить сохранённый APK." }
                        require(partial.renameTo(completed)) { "Не удалось сохранить проверенное обновление." }
                    } else {
                        stage(request, "verifying")
                        validateArchive(descriptor, completed)
                    }
                } finally {
                    // Only our own incomplete cache file, never subscriptions or user files.
                    partial.delete()
                }
                request.download.checkCancelled()
                request.verifiedFile = completed
                handler.post { if (active(request)) requestInstall(request) }
            } catch (error: Throwable) {
                handler.post {
                    finish(request, json(false, friendlyError(error), request.cancelled.get()))
                }
            }
        }
    }

    fun cancel(): String {
        pending?.let { request ->
            request.download.cancel()
            request.task?.cancel(true)
            finish(request, json(false, "Загрузка обновления отменена. VPN продолжает работать.", true))
        }
        return json(true)
    }

    fun onPause() {
        pending?.takeIf { it.awaitingPermission }?.leftForPermission = true
    }

    fun onResume() {
        pending?.takeIf { it.awaitingPermission && it.leftForPermission }?.let(::resumePermission)
    }

    fun onActivityResult(requestCode: Int): Boolean {
        if (requestCode !in FIRST_INSTALL_PERMISSION_CODE..LAST_INSTALL_PERMISSION_CODE) return false
        pending?.takeIf { it.awaitingPermission && it.permissionCode == requestCode }?.let(::resumePermission)
        return true
    }

    fun close() {
        closed = true
        cancel()
        executor.shutdownNow()
    }

    private fun resumePermission(request: Request) {
        if (!active(request)) return
        request.awaitingPermission = false
        if (activity.packageManager.canRequestPackageInstalls()) {
            openInstaller(request)
        } else {
            finish(request, json(false,
                "Установка не разрешена. Разрешите «Установку неизвестных приложений» для Dropo и нажмите «Обновить» снова. Проверенный APK сохранён."))
        }
    }

    private fun requestInstall(request: Request) {
        if (!active(request)) return
        if (!activity.packageManager.canRequestPackageInstalls()) {
            stage(request, "permission")
            request.awaitingPermission = true
            try {
                activity.startActivityForResult(Intent(
                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:${activity.packageName}"),
                ), request.permissionCode)
            } catch (_: ActivityNotFoundException) {
                request.awaitingPermission = false
                finish(request, json(false,
                    "Не удалось открыть разрешение установки. Откройте настройки Android → Приложения → Dropo → Установка неизвестных приложений, затем повторите обновление."))
            } catch (_: SecurityException) {
                request.awaitingPermission = false
                finish(request, json(false, "Установка приложений ограничена настройками Android или администратором устройства."))
            }
        } else {
            openInstaller(request)
        }
    }

    private fun openInstaller(request: Request) {
        if (!active(request)) return
        try {
            val file = request.verifiedFile ?: error("Проверенный APK отсутствует.")
            require(file.isFile) { "Сохранённый APK удалён системой. Повторите обновление." }
            val uri = FileProvider.getUriForFile(activity, "${activity.packageName}.updates", file)
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                clipData = android.content.ClipData.newRawUri("Dropo update", uri)
            }
            stage(request, "installing")
            activity.startActivity(intent)
            finish(request, JSONObject(mapOf(
                "success" to true, "installerOpened" to true,
                "stage" to "ready", "latestVersion" to request.descriptor?.version,
            )).toString())
        } catch (_: ActivityNotFoundException) {
            finish(request, json(false, "Системный установщик APK недоступен. Проверьте ограничения телефона и повторите обновление."))
        } catch (_: SecurityException) {
            finish(request, json(false, "Android запретил установку. Проверьте разрешение установки приложений для Dropo."))
        } catch (error: Throwable) {
            finish(request, json(false, friendlyError(error)))
        }
    }

    @Suppress("DEPRECATION")
    private fun validateArchive(descriptor: AndroidUpdateDescriptor, file: File) {
        val manager = activity.packageManager
        val installed = manager.getPackageInfo(activity.packageName, PackageManager.GET_SIGNING_CERTIFICATES)
        val archive = manager.getPackageArchiveInfo(file.absolutePath, PackageManager.GET_SIGNING_CERTIFICATES)
            ?: error("Android не распознал загруженный APK.")
        val abis = ZipFile(file).use { zip ->
            zip.entries().asSequence()
                .map { it.name }.filter { it.matches(Regex("lib/[^/]+/libflutter\\.so")) }
                .map { it.split('/')[1] }.toSet()
        }
        AndroidUpdatePolicy.validateArchive(
            descriptor, activity.packageName, installed.longVersionCode, signerDigests(installed),
            archive.packageName, archive.versionName.orEmpty(), archive.longVersionCode, signerDigests(archive),
            archive.applicationInfo?.minSdkVersion ?: Int.MAX_VALUE,
            Build.VERSION.SDK_INT, Build.SUPPORTED_ABIS.toSet(), abis,
        )
    }

    private fun signerDigests(info: PackageInfo): Set<String> =
        info.signingInfo?.apkContentsSigners?.map { signer ->
            MessageDigest.getInstance("SHA-256").digest(signer.toByteArray())
                .joinToString("") { "%02x".format(it.toInt() and 0xff) }
        }?.toSet().orEmpty()

    private fun stage(request: Request, stage: String) =
        event(request, "update-stage", mapOf("stage" to stage, "version" to request.descriptor?.version))

    private fun event(request: Request, name: String, payload: Map<String, Any?>) {
        handler.post {
            if (pending === request && !closed && !request.cancelled.get()) {
                DropoVpnRuntime.emitUpdateEvent(name, payload)
            }
        }
    }

    private fun finish(request: Request, response: String) {
        if (pending !== request) return
        pending = null
        request.watchdog?.let(handler::removeCallbacks)
        request.result.success(response)
    }

    private fun active(request: Request): Boolean {
        if (pending !== request || closed || request.cancelled.get()) return false
        if (request.fence.expired()) {
            expire(request)
            return false
        }
        return request.fence.canResume()
    }

    private fun expire(request: Request) {
        if (pending !== request) return
        request.download.cancel()
        request.task?.cancel(true)
        finish(request, json(false,
            "Время обновления истекло. Нажмите «Обновить» снова; проверенный APK, если он уже загружен, будет использован повторно."))
    }

    private fun friendlyError(error: Throwable): String = when {
        error is AndroidUpdateCancelled -> error.message.orEmpty()
        error is AndroidUpdateDownloadFailure -> error.message.orEmpty()
        error is SocketTimeoutException -> "GitHub не отвечает. Проверьте интернет и повторите обновление."
        error is UnknownHostException -> "Не удалось подключиться к GitHub. Проверьте интернет и DNS."
        error is IllegalArgumentException || error is IllegalStateException ->
            error.message ?: "Проверка APK не пройдена."
        else -> "Не удалось загрузить обновление. Проверьте интернет и повторите попытку."
    }

    private fun json(success: Boolean, error: String = "", cancelled: Boolean = false): String =
        JSONObject(mapOf("success" to success, "error" to error, "cancelled" to cancelled)).toString()

    companion object {
        private const val FIRST_INSTALL_PERMISSION_CODE = 4200
        private const val LAST_INSTALL_PERMISSION_CODE = 14200
    }
}
