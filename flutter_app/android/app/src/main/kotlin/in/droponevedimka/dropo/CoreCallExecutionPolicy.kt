package `in`.droponevedimka.dropo

/** Select a lane only; never execute or reinterpret a core call here. */
internal object CoreCallExecutionPolicy {
    private val networkMethods = setOf(
        "TestVPNConnection",
        "AddVPNSource",
        "AddPublicVPNSource",
        "AddManagedVPNSource",
        "RefreshVPNSources",
        "RunClientQuickCheck",
        "RunClientQuickCheckReadOnly",
    )

    fun usesNetworkExecutor(channelMethod: String, coreMethod: String?): Boolean =
        channelMethod == "call" && coreMethod in networkMethods
}
