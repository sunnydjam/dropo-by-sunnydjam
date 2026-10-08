package `in`.droponevedimka.dropo

import java.util.concurrent.CountDownLatch
import java.util.concurrent.Semaphore
import java.util.concurrent.TimeUnit
import org.junit.Assert.*
import org.junit.Test

class NativeLogDispatcherTest {
    @Test
    fun callbackReturnsBeforeLogSinkAcquiresTheCallersGoLock() {
        val coreLock = Semaphore(0)
        val entered = CountDownLatch(1)
        val written = CountDownLatch(1)
        val dispatcher = NativeLogDispatcher { method, arguments ->
            entered.countDown()
            assertTrue(coreLock.tryAcquire(2, TimeUnit.SECONDS))
            assertEquals("AndroidSingBoxLog", method)
            assertEquals("[]", arguments)
            written.countDown()
        }
        try {
            dispatcher.post("AndroidSingBoxLog", "[]")
            assertTrue(entered.await(2, TimeUnit.SECONDS))
            assertEquals(1L, written.count)
            coreLock.release()
            assertTrue(written.await(2, TimeUnit.SECONDS))
        } finally {
            dispatcher.close()
        }
    }

    @Test
    fun callbacksAfterDestroyAreIgnored() {
        val written = CountDownLatch(1)
        val dispatcher = NativeLogDispatcher { _, _ -> written.countDown() }
        dispatcher.close()
        dispatcher.post("AndroidSingBoxLog", "[]")
        assertFalse(written.await(100, TimeUnit.MILLISECONDS))
    }
}
