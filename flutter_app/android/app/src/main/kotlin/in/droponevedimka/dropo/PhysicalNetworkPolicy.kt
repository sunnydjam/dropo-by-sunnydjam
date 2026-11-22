package `in`.droponevedimka.dropo

internal enum class PhysicalTransport { WIFI, CELLULAR, ETHERNET, OTHER }

/** VPN capabilities may inherit Wi-Fi/cellular flags; never use the TUN as physical DNS. */
internal object PhysicalNetworkPolicy {
    fun usable(internet: Boolean, notVpn: Boolean, vpn: Boolean): Boolean =
        internet && notVpn && !vpn

    fun transport(
        vpn: Boolean,
        notVpn: Boolean,
        wifi: Boolean,
        cellular: Boolean,
        ethernet: Boolean,
    ): PhysicalTransport = when {
        vpn || !notVpn -> PhysicalTransport.OTHER
        wifi -> PhysicalTransport.WIFI
        cellular -> PhysicalTransport.CELLULAR
        ethernet -> PhysicalTransport.ETHERNET
        else -> PhysicalTransport.OTHER
    }

    /** Keep all interfaces and their relative order, but enumerate the selected network first. */
    fun <T> preferredFirst(networks: List<T>, preferred: T?): List<T> =
        networks.sortedBy { if (preferred != null && it == preferred) 0 else 1 }
}
