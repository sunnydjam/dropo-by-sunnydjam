package `in`.droponevedimka.dropo

import java.util.concurrent.CountDownLatch
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.*
import org.junit.Test

class ReviewPromptTrackerTest {
    private class MemoryStore : ReviewPromptStore {
        var state = ReviewPromptState()
        var failWrites = false
        override fun read() = state
        override fun write(state: ReviewPromptState): Boolean {
            if (failWrites) return false
            this.state = state
            return true
        }
    }

    @Test fun onlyThreeCompletedSuccessfulCyclesQualify() {
        val store = MemoryStore()
        val tracker = ReviewPromptTracker(store) { 10L }
        repeat(2) {
            tracker.connected(); tracker.disconnected(true)
            assertFalse(tracker.snapshot().eligible)
        }
        tracker.connected()
        assertFalse(tracker.snapshot().eligible)
        tracker.disconnected(true)
        assertTrue(tracker.snapshot().eligible)
        assertEquals(3, store.state.completedCycles)
    }

    @Test fun failedStartsRevocationAndDuplicateStopsDoNotCount() {
        val store = MemoryStore()
        val tracker = ReviewPromptTracker(store) { 10L }
        tracker.disconnected(true)
        repeat(4) { tracker.connected(); tracker.disconnected(false) }
        tracker.disconnected(true) // Late cleanup after a failure is not success.
        tracker.connected(); tracker.disconnected(true); tracker.disconnected(true)
        assertEquals(1, store.state.completedCycles)
        assertFalse(tracker.snapshot().eligible)
    }

    @Test fun uninterruptedSessionQualifiesAtExactly24Hours() {
        val store = MemoryStore()
        var now = 100L
        val tracker = ReviewPromptTracker(store) { now }
        tracker.connected()
        now += ReviewPromptTracker.REQUIRED_SESSION_MILLIS - 1
        assertFalse(tracker.snapshot().eligible)
        now++
        assertTrue(tracker.snapshot().eligible)
        assertNotNull(tracker.claim())
        assertTrue(store.state.shown)
    }

    @Test fun duplicateConnectedDoesNotResetDurationAndClockRollbackDoesNotQualify() {
        var now = 100L
        val tracker = ReviewPromptTracker(MemoryStore()) { now }
        tracker.connected()
        now = 0
        assertFalse(tracker.snapshot().eligible)
        now = 100 + ReviewPromptTracker.REQUIRED_SESSION_MILLIS
        tracker.connected()
        assertTrue(tracker.snapshot().eligible)
    }

    @Test fun shortSessionsAreNotAddedTo24HourThreshold() {
        var now = 0L
        val tracker = ReviewPromptTracker(MemoryStore()) { now }
        repeat(2) {
            tracker.connected(); now += 13L * 60 * 60 * 1000
            tracker.disconnected(true)
        }
        assertFalse(tracker.snapshot().eligible)
    }

    @Test fun completedLongSessionRemainsEligibleAfterServiceRestart() {
        val store = MemoryStore()
        var now = 0L
        val tracker = ReviewPromptTracker(store) { now }
        tracker.connected(); now = ReviewPromptTracker.REQUIRED_SESSION_MILLIS
        tracker.disconnected(true)
        assertTrue(ReviewPromptTracker(store) { 0L }.snapshot().eligible)
    }

    @Test fun killedServiceDoesNotRestoreUnverifiedSessionOrLoseCompletedCycles() {
        val store = MemoryStore()
        var now = 0L
        val tracker = ReviewPromptTracker(store) { now }
        tracker.connected(); tracker.disconnected(true); tracker.connected()
        now = ReviewPromptTracker.REQUIRED_SESSION_MILLIS
        val restarted = ReviewPromptTracker(store) { now }
        assertFalse(restarted.snapshot().eligible)
        assertEquals(1, restarted.snapshot().completedCycles)
    }

    @Test fun concurrentClaimsAndNewInstancesNeverShowTwice() {
        val store = MemoryStore().also { it.state = ReviewPromptState(3, true) }
        val tracker = ReviewPromptTracker(store) { 0L }
        val start = CountDownLatch(1)
        val claims = AtomicInteger()
        val threads = List(8) { Thread { start.await(); if (tracker.claim() != null) claims.incrementAndGet() } }
        threads.forEach { it.start() }; start.countDown(); threads.forEach { it.join() }
        assertEquals(1, claims.get())
        assertNull(ReviewPromptTracker(store) { 0L }.claim())
    }

    @Test fun failedDurableWriteNeverAuthorizesPresentation() {
        val store = MemoryStore().also { it.state = ReviewPromptState(3, true); it.failWrites = true }
        val tracker = ReviewPromptTracker(store) { 0L }
        assertNull(tracker.claim())
        assertFalse(store.state.shown)
        store.failWrites = false
        assertNotNull(tracker.claim())
    }
    @Test fun onlyTheOwnerCanReleaseAPromptThatNeverOpened() {
        val store = MemoryStore().also { it.state = ReviewPromptState(3, true) }
        val tracker = ReviewPromptTracker(store) { 0L }
        val first = tracker.claim()!!
        assertFalse(tracker.cancelUnpresentedClaim("wrong"))
        assertTrue(tracker.cancelUnpresentedClaim(first))
        assertFalse(store.state.shown)
        val second = tracker.claim()!!
        assertFalse(tracker.cancelUnpresentedClaim(first))
        assertTrue(tracker.confirmPresentation(second))
        assertFalse(tracker.cancelUnpresentedClaim(second))
        assertTrue(store.state.shown)
        assertNull(ReviewPromptTracker(store) { 0L }.claim())
    }

}
