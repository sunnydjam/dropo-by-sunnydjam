package `in`.droponevedimka.dropo

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AndroidDistributionPolicyTest {
    @Test fun playBlocksEveryApkUpdateEntryPoint() {
        for (method in listOf("androidInstallUpdate", "CheckForUpdates", "InstallUpdate", "CancelAndroidUpdate")) {
            assertTrue(AndroidDistributionPolicy.blocksMethod(true, method))
            assertFalse(AndroidDistributionPolicy.blocksMethod(false, method))
        }
    }
    @Test fun playPreservesVpnAndSubscriptionCalls() {
        for (method in listOf("setConnected", "status", "GetVPNSourceList", "UpdateSubscriptions", "androidVpnProtection")) {
            assertFalse(AndroidDistributionPolicy.blocksMethod(true, method))
        }
    }
}
