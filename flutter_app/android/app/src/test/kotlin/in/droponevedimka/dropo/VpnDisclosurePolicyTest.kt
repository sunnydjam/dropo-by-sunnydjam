package `in`.droponevedimka.dropo

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class VpnDisclosurePolicyTest {
    @Test fun missingConsentDoesNotStartVpn() {
        assertFalse(VpnDisclosurePolicy.isAccepted(0))
    }

    @Test fun currentAffirmativeConsentIsAccepted() {
        assertTrue(VpnDisclosurePolicy.isAccepted(VpnDisclosurePolicy.VERSION))
        assertTrue(VpnDisclosurePolicy.canAccept(VpnDisclosurePolicy.VERSION))
    }

    @Test fun obsoleteOrUnknownVersionsRequireVisibleDisclosureAgain() {
        for (version in listOf(-1, 0, VpnDisclosurePolicy.VERSION + 1, Int.MAX_VALUE)) {
            assertFalse(VpnDisclosurePolicy.isAccepted(version))
            assertFalse(VpnDisclosurePolicy.canAccept(version))
        }
    }
}
