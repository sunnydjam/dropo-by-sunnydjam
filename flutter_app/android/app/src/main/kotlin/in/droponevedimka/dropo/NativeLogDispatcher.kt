package `in`.droponevedimka.dropo

import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit

/** A libbox callback must return before a log sink can acquire Go core locks. */
internal class NativeLogDispatcher(private val sink: (String, String) -> Unit) {
    private val executor = ThreadPoolExecutor(
        1,
        1,
        0L,
        TimeUnit.MILLISECONDS,
        ArrayBlockingQueue(128),
        { runnable -> Thread(runnable, "DropoVpnLogs") },
        ThreadPoolExecutor.DiscardOldestPolicy(),
    )

    fun post(method: String, arguments: String) {
        if (executor.isShutdown) return
        runCatching {
            executor.execute { runCatching { sink(method, arguments) } }
        }
    }

    fun close() {
        executor.shutdownNow()
    }
}
