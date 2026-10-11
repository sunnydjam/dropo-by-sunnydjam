package `in`.droponevedimka.dropo

import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import org.junit.Assert.*
import org.junit.Test

class CoreCallExecutionPolicyTest {
    @Test
    fun bothQuickCheckMethodsUseTheNetworkLane() {
        assertTrue(CoreCallExecutionPolicy.usesNetworkExecutor("call", "RunClientQuickCheckReadOnly"))
        assertTrue(CoreCallExecutionPolicy.usesNetworkExecutor("call", "RunClientQuickCheck"))
    }

    @Test
    fun sourceDownloadCallsKeepTheirExistingNetworkLane() {
        for (method in listOf(
            "TestVPNConnection", "AddVPNSource", "AddPublicVPNSource",
            "AddManagedVPNSource", "RefreshVPNSources",
        )) {
            assertTrue(method, CoreCallExecutionPolicy.usesNetworkExecutor("call", method))
        }
    }

    @Test
    fun statusEventsShutdownAndLifecycleWorkKeepTheCoreLane() {
        for (method in listOf(
            "ensureStarted", "status", "events", "logs", "serviceStatus",
            "diagnostics", "shutdown", "setConnected",
        )) {
            assertFalse(method, CoreCallExecutionPolicy.usesNetworkExecutor(method, null))
            // A payload cannot move an outer status/event call to another lane.
            assertFalse(method, CoreCallExecutionPolicy.usesNetworkExecutor(method, "RunClientQuickCheckReadOnly"))
        }
    }

    @Test
    fun shortRouteAndConfigCallsRemainOrderedOnTheCoreLane() {
        for (method in listOf(
            "GetStatus", "GetRoutes", "GetAppConfig", "GetVPNSources",
            "SetRoutePolicy", "SetRoutingMode", "SetVPNSourceNode",
            "SetVPNSourceEnabled", "MoveVPNSource", "RemoveVPNSource",
            "AndroidServiceState", "AndroidEngineLog", "unknown-method",
        )) {
            assertFalse(method, CoreCallExecutionPolicy.usesNetworkExecutor("call", method))
        }
        assertFalse(CoreCallExecutionPolicy.usesNetworkExecutor("call", null))
        assertFalse(CoreCallExecutionPolicy.usesNetworkExecutor("call", ""))
    }

    @Test
    fun aBlockedProbeDoesNotQueueStatusEventsOrShutdownBehindIt() {
        for (probe in listOf("RunClientQuickCheckReadOnly", "RunClientQuickCheck")) {
            val coreExecutor = Executors.newSingleThreadExecutor()
            val networkExecutor = Executors.newSingleThreadExecutor()
            val entered = CountDownLatch(1)
            val release = CountDownLatch(1)
            fun lane(channelMethod: String, coreMethod: String?) =
                if (CoreCallExecutionPolicy.usesNetworkExecutor(channelMethod, coreMethod)) {
                    networkExecutor
                } else {
                    coreExecutor
                }
            try {
                val slowProbe = lane("call", probe).submit<Boolean> {
                    entered.countDown()
                    release.await(3, TimeUnit.SECONDS)
                }
                assertTrue(entered.await(2, TimeUnit.SECONDS))
                for (method in listOf("status", "events", "serviceStatus", "shutdown")) {
                    assertTrue(lane(method, null).submit<Boolean> { true }.get(1, TimeUnit.SECONDS))
                }
                assertFalse(slowProbe.isDone)
                release.countDown()
                assertTrue(slowProbe.get(2, TimeUnit.SECONDS))
            } finally {
                release.countDown()
                coreExecutor.shutdownNow()
                networkExecutor.shutdownNow()
            }
        }
    }
}
