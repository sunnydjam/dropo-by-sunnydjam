package `in`.droponevedimka.dropo

/** Play never downloads or installs application updates outside the store. */
internal object AndroidDistributionPolicy {
    fun blocksMethod(playDistribution: Boolean, method: String): Boolean =
        playDistribution && method in setOf(
            "androidInstallUpdate", "CheckForUpdates", "InstallUpdate", "CancelAndroidUpdate",
        )
}
