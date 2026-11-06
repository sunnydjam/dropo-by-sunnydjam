package `in`.droponevedimka.dropo

data class ReviewPromptState(
    val completedCycles: Int = 0,
    val eligible: Boolean = false,
    val shown: Boolean = false,
)

interface ReviewPromptStore {
    fun read(): ReviewPromptState
    fun write(state: ReviewPromptState): Boolean
}

/** One lifetime request per app data store; no account or network dependency. */
class ReviewPromptTracker(
    private val store: ReviewPromptStore,
    private val elapsedMillis: () -> Long,
) {
    private var connectedAt: Long? = null

    @Synchronized
    fun connected() {
        // Duplicate start callbacks must not reset a long-running session.
        if (connectedAt == null) connectedAt = elapsedMillis()
    }

    @Synchronized
    fun disconnected(successfully: Boolean) {
        val start = connectedAt ?: return
        connectedAt = null
        if (!successfully) return
        val state = store.read()
        if (state.shown) return
        val cycles = (state.completedCycles.coerceIn(0, REQUIRED_CYCLES) + 1)
            .coerceAtMost(REQUIRED_CYCLES)
        store.write(state.copy(
            completedCycles = cycles,
            eligible = state.eligible || cycles >= REQUIRED_CYCLES || longSession(start),
        ))
    }

    @Synchronized
    fun snapshot(): ReviewPromptState {
        val state = store.read()
        val eligible = state.eligible || state.completedCycles >= REQUIRED_CYCLES ||
            connectedAt?.let(::longSession) == true
        return state.copy(eligible = eligible)
    }

    @Synchronized
    fun claim(): Boolean {
        val state = snapshot()
        if (!state.eligible || state.shown) return false
        // Durable before presentation: a restart or concurrent UI request must
        // never display a second prompt, even after dismissal or link failure.
        return store.write(state.copy(shown = true))
    }

    private fun longSession(start: Long): Boolean {
        val now = elapsedMillis()
        return now >= start && now - start >= REQUIRED_SESSION_MILLIS
    }

    companion object {
        const val REQUIRED_CYCLES = 3
        const val REQUIRED_SESSION_MILLIS = 24L * 60 * 60 * 1000
    }
}
