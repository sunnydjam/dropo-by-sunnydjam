package `in`.droponevedimka.dropo

import android.app.Activity
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import com.google.android.play.core.review.ReviewInfo
import com.google.android.play.core.review.ReviewManager
import com.google.android.play.core.review.ReviewManagerFactory
import java.util.concurrent.Executor

/** Google owns its card, quota and outcome; never infer that a review was shown. */
class PlayReviewClient(
    private val activity: Activity,
    private val tracker: ReviewPromptTracker,
    private val worker: Executor,
    private val canPresent: () -> Boolean,
    private val manager: ReviewManager = ReviewManagerFactory.create(activity),
) {
    private val handler = Handler(Looper.getMainLooper())
    private var info: ReviewInfo? = null
    private var preparedAt = 0L
    private var preparing = false
    private var closed = false
    private var pendingPreparation: ((Map<String, Boolean>) -> Unit)? = null

    fun prepare(reply: (Map<String, Boolean>) -> Unit) {
        if (closed || !canPresent() || preparing) {
            reply(mapOf("prepared" to false, "retryLater" to true))
            return
        }
        if (info != null && SystemClock.elapsedRealtime() - preparedAt < INFO_MAX_AGE_MS) {
            reply(mapOf("prepared" to true))
            return
        }
        info = null
        preparing = true
        var completed = false
        lateinit var timeout: Runnable
        val finish: (Map<String, Boolean>) -> Unit = { response ->
            if (!completed) {
                completed = true
                preparing = false
                pendingPreparation = null
                handler.removeCallbacks(timeout)
                reply(response)
            }
        }
        timeout = Runnable { finish(mapOf("prepared" to false)) }
        pendingPreparation = finish
        handler.postDelayed(timeout, REQUEST_TIMEOUT_MS)
        val request = try {
            manager.requestReviewFlow()
        } catch (_: Exception) {
            finish(mapOf("prepared" to false))
            return
        }
        request.addOnCompleteListener { task ->
            if (completed || closed) return@addOnCompleteListener
            if (!task.isSuccessful) {
                finish(mapOf("prepared" to false))
            } else if (!canPresent()) {
                finish(mapOf("prepared" to false, "retryLater" to true))
            } else {
                info = task.result
                preparedAt = SystemClock.elapsedRealtime()
                finish(mapOf("prepared" to true))
            }
        }
    }

    fun launch(claimId: String, reply: (Map<String, Boolean>) -> Unit) {
        val prepared = info
        info = null
        if (closed || !canPresent() || prepared == null ||
            SystemClock.elapsedRealtime() - preparedAt >= INFO_MAX_AGE_MS) {
            // No Google launch occurred. Release only this still-unpresented
            // reservation, off the UI thread, for a later foreground attempt.
            worker.execute {
                runCatching { tracker.cancelUnpresentedClaim(claimId) }
                activity.runOnUiThread {
                    reply(mapOf("attempted" to false, "retryLater" to true))
                }
            }
            return
        }
        // Memory-only confirmation: no await between the foreground check and
        // handing the card to Google. The durable one-time flag already exists.
        if (!tracker.confirmPresentation(claimId)) {
            reply(mapOf("attempted" to false))
            return
        }
        try {
            manager.launchReviewFlow(activity, prepared).addOnCompleteListener {
                // Even success cannot tell us if the card appeared or a review
                // was written. Never launch a store/browser fallback here.
                reply(mapOf("attempted" to true))
            }
        } catch (_: Exception) {
            // Once launch was attempted its outcome is unknown. Consume the
            // one-time budget and continue normal app use without an error UI.
            reply(mapOf("attempted" to true))
        }
    }

    fun close() {
        closed = true
        info = null
        pendingPreparation?.invoke(mapOf("prepared" to false))
        // Do not cancel or programmatically dismiss an already launched card.
    }

    companion object {
        const val PLAY_APPLICATION_ID = "com.dropo.myapp"
        private const val REQUEST_TIMEOUT_MS = 10_000L
        private const val INFO_MAX_AGE_MS = 30_000L
    }
}
