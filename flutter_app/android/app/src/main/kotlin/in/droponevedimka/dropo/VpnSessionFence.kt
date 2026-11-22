package `in`.droponevedimka.dropo

/** Invalidates asynchronous starts before their downloads or callbacks finish. */
internal class VpnSessionFence {
    private var generation = 0L
    private var active = false
    private var destroyed = false

    @Synchronized
    fun begin(): Long? {
        if (destroyed || active) return null
        active = true
        generation += 1
        return generation
    }

    @Synchronized
    fun cancel() {
        active = false
        generation += 1
    }

    @Synchronized
    fun destroy() {
        destroyed = true
        cancel()
    }

    @Synchronized
    fun isActive(candidate: Long): Boolean = active && !destroyed && candidate == generation

    /** Keep a short native commit atomic with cancellation; never download here. */
    @Synchronized
    fun commit(candidate: Long, action: () -> Unit): Boolean {
        if (!isActive(candidate)) return false
        action()
        return true
    }
}
