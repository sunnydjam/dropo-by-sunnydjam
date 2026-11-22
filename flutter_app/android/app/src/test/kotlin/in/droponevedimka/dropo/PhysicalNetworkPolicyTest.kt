package `in`.droponevedimka.dropo

import org.junit.Assert.*
import org.junit.Test

class PhysicalNetworkPolicyTest {
    @Test
    fun vpnInheritingWifiOrCellularIsNotPhysical() {
        assertEquals(PhysicalTransport.OTHER, PhysicalNetworkPolicy.transport(true, true, true, true, false))
        assertFalse(PhysicalNetworkPolicy.usable(true, true, true))
        assertEquals(PhysicalTransport.OTHER, PhysicalNetworkPolicy.transport(false, false, true, false, false))
        assertFalse(PhysicalNetworkPolicy.usable(true, false, false))
    }

    @Test
    fun physicalTransportsRemainAvailable() {
        assertEquals(PhysicalTransport.WIFI, PhysicalNetworkPolicy.transport(false, true, true, false, false))
        assertEquals(PhysicalTransport.CELLULAR, PhysicalNetworkPolicy.transport(false, true, false, true, false))
        assertEquals(PhysicalTransport.ETHERNET, PhysicalNetworkPolicy.transport(false, true, false, false, true))
        assertTrue(PhysicalNetworkPolicy.usable(true, true, false))
        assertFalse(PhysicalNetworkPolicy.usable(false, true, false))
    }

    @Test
    fun selectedMobileNetworkPrecedesInactiveWifiAndTunWithoutDroppingInterfaces() {
        val networks = listOf("wifi", "tun", "cellular", "ethernet")
        assertEquals(listOf("cellular", "wifi", "tun", "ethernet"), PhysicalNetworkPolicy.preferredFirst(networks, "cellular"))
        assertEquals(networks, PhysicalNetworkPolicy.preferredFirst(networks, null))
        assertEquals(networks, PhysicalNetworkPolicy.preferredFirst(networks, "missing"))
    }
}
