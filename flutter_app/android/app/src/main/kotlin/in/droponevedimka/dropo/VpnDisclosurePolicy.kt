package `in`.droponevedimka.dropo

/** Explicit, versioned consent; old or future versions never imply acceptance. */
internal object VpnDisclosurePolicy {
    const val VERSION = 1
    const val REQUIRED_MESSAGE =
        "Откройте Dropo и подтвердите объяснение использования VPN перед подключением."

    fun isAccepted(storedVersion: Int): Boolean = storedVersion == VERSION
    fun canAccept(requestedVersion: Int): Boolean = requestedVersion == VERSION
}
