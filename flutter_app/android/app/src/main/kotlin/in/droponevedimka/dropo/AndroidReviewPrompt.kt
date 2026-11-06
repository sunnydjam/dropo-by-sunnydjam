package `in`.droponevedimka.dropo

import android.content.Context
import android.os.SystemClock

object AndroidReviewPrompt {
    private var tracker: ReviewPromptTracker? = null

    @Synchronized
    fun tracker(context: Context): ReviewPromptTracker {
        return tracker ?: ReviewPromptTracker(
            object : ReviewPromptStore {
                private val preferences = context.applicationContext
                    .getSharedPreferences("dropo_review_prompt", Context.MODE_PRIVATE)

                override fun read() = ReviewPromptState(
                    completedCycles = preferences.getInt("completed_cycles", 0),
                    eligible = preferences.getBoolean("eligible", false),
                    shown = preferences.getBoolean("shown", false),
                )

                override fun write(state: ReviewPromptState): Boolean = preferences.edit()
                    .putInt("completed_cycles", state.completedCycles)
                    .putBoolean("eligible", state.eligible)
                    .putBoolean("shown", state.shown)
                    .commit()
            },
            SystemClock::elapsedRealtime,
        ).also { tracker = it }
    }
}
