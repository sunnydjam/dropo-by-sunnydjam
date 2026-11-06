package `in`.droponevedimka.dropo

object PlayStoreListing {
    const val URL = "https://play.google.com/store/apps/details?id=com.dropo.myapp"
    const val STORE_PACKAGE = "com.android.vending"

    /** The public, documented listing URL; there is no promised review editor URI. */
    fun open(
        inStore: () -> Unit,
        inBrowser: () -> Unit,
        missingHandler: (Exception) -> Boolean,
    ): Boolean {
        try {
            inStore()
            return true
        } catch (error: Exception) {
            if (!missingHandler(error)) return false
        }
        return try { inBrowser(); true } catch (_: Exception) { false }
    }
}
