package `in`.droponevedimka.dropo

import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import org.junit.Assert.*
import org.junit.Test

class VpnSessionFenceTest {
    @Test
    fun stopDuringDownloadRejectsLateTunAndConnectedCommits() {
        val fence = VpnSessionFence()
        val generation = fence.begin()!!
        val downloaded = CountDownLatch(1)
        val finished = CountDownLatch(1)
        val established = AtomicBoolean(false)
        val connected = AtomicBoolean(false)
        val worker = Thread {
            assertTrue(downloaded.await(2, TimeUnit.SECONDS))
            fence.commit(generation) { established.set(true) }
            fence.commit(generation) { connected.set(true) }
            finished.countDown()
        }
        worker.start()
        fence.cancel()
        downloaded.countDown()
        assertTrue(finished.await(2, TimeUnit.SECONDS))
        worker.join()
        assertFalse(established.get())
        assertFalse(connected.get())
    }

    @Test
    fun oldNetworkCallbackCannotCommitIntoNewSession() {
        val fence = VpnSessionFence()
        val old = fence.begin()!!
        fence.cancel()
        val current = fence.begin()!!
        assertFalse(fence.commit(old) { fail("stale callback committed") })
        assertTrue(fence.commit(current) {})
    }

    @Test
    fun destroyPermanentlyRejectsStartsAndPendingCommits() {
        val fence = VpnSessionFence()
        val generation = fence.begin()!!
        fence.destroy()
        assertNull(fence.begin())
        assertFalse(fence.commit(generation) { fail("destroyed service committed") })
    }

    @Test
    fun duplicateStartDoesNotInvalidateActiveSession() {
        val fence = VpnSessionFence()
        val generation = fence.begin()!!
        assertNull(fence.begin())
        assertTrue(fence.isActive(generation))
    }
}
