package `in`.droponevedimka.dropo

import android.content.Context

/** App-private preferences are excluded from backups by the application manifest. */
internal object VpnDisclosureConsent {
    private const val PREFERENCES = "dropo_vpn_disclosure"
    private const val ACCEPTED_VERSION = "accepted_version"

    fun isAccepted(context: Context): Boolean = VpnDisclosurePolicy.isAccepted(
        context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
            .getInt(ACCEPTED_VERSION, 0),
    )

    fun accept(context: Context, version: Int): Boolean {
        if (!VpnDisclosurePolicy.canAccept(version)) return false
        // The caller must not start VPN until persistence has succeeded.
        return context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
            .edit().putInt(ACCEPTED_VERSION, version).commit()
    }
}
