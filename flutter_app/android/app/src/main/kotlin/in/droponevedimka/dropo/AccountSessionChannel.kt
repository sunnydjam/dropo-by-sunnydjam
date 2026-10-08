package `in`.droponevedimka.dropo

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.atomic.AtomicBoolean

/** Independent ordered worker: Keystore/file IO never blocks VPN/status calls. */
internal class AccountSessionChannel(context: Context, messenger: BinaryMessenger) {
    private val store = SecureAccountSessionStore(context)
    private val executor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())
    private val closed = AtomicBoolean(false)
    private val channel = MethodChannel(messenger, "dropo/account_session")

    init {
        channel.setMethodCallHandler { call, result ->
            if (call.method !in setOf("read", "write", "clear")) {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val token = if (call.method == "write") {
                (call.arguments as? Map<*, *>)?.get("token") as? String
            } else null
            if (call.method == "write" &&
                (token == null || !AccountSessionEnvelope.validToken(token))) {
                result.error("ACCOUNT_SESSION_INVALID", "Invalid account session token.", null)
                return@setMethodCallHandler
            }
            try {
                executor.execute {
                    if (closed.get()) return@execute
                    try {
                        val response = when (call.method) {
                            "read" -> store.read()
                            "write" -> { store.write(token!!); null }
                            else -> { store.clear(); null }
                        }
                        mainHandler.post { if (!closed.get()) result.success(response) }
                    } catch (_: Exception) {
                        // Never expose exception messages, file contents, keys,
                        // or session tokens through logging or platform errors.
                        mainHandler.post { if (!closed.get()) unavailable(result) }
                    }
                }
            } catch (_: RejectedExecutionException) {
                unavailable(result)
            }
        }
    }

    private fun unavailable(result: MethodChannel.Result) {
        result.error("ACCOUNT_SESSION_UNAVAILABLE",
            "Protected account session storage is unavailable.", null)
    }

    fun close() {
        closed.set(true)
        channel.setMethodCallHandler(null)
        executor.shutdownNow()
    }
}
