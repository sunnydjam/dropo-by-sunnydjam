package `in`.droponevedimka.dropo

import android.content.Context

// Only these fixed codes are persisted. Never store an exception or an address.
internal enum class ConnectionFailure(val code: String) {
    DISCLOSURE("permission.disclosure_required"),
    DENIED("permission.denied"),
    REQUEST_FAILED("permission.request_failed"),
    SOURCE("source.source_unavailable"),
    DISABLED("source.all_disabled"),
    SERVICE("service.start_failed"),
    TIMEOUT("service.start_timeout"),
    CONFIG("config.prepare_failed"),
    TUNNEL("tunnel.start_failed"),
    REVOKED("permission.revoked"),
    SELECTOR("verification.selector_unavailable"),
    NO_RESPONSE("verification.no_verified_entry");

    fun save(context: Context) {
        context.getSharedPreferences("connection_diagnostics", Context.MODE_PRIVATE)
            .edit().putString("last_failure", code).apply()
    }

    companion object {
        fun last(context: Context): String =
            context.getSharedPreferences("connection_diagnostics", Context.MODE_PRIVATE)
                .getString("last_failure", "").orEmpty()
    }
}
