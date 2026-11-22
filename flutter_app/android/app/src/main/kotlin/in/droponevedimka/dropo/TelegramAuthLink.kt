package `in`.droponevedimka.dropo

import java.net.URI

/** A narrowly scoped bot-auth handoff; ordinary Telegram/web links are not rewritten. */
internal class TelegramAuthLink private constructor(
    val httpsUrl: String,
    val telegramUrl: String,
) {
    companion object {
        private val botUsername = Regex("[A-Za-z][A-Za-z0-9_]{4,31}")
        private val authStart = Regex("(?:login_|recover_)[A-Za-z0-9_-]+")

        fun fromHttps(value: String): TelegramAuthLink? {
            // A canonical bot auth URL is much smaller; bound parsing without logging it.
            if (value.length > 256) return null
            val uri = try {
                URI(value)
            } catch (_: Exception) {
                return null
            }
            if (uri.scheme != "https" || uri.host != "t.me" ||
                uri.rawAuthority !in setOf("t.me", "t.me:443") ||
                uri.userInfo != null || uri.fragment != null ||
                (uri.port != -1 && uri.port != 443)) return null

            val bot = uri.rawPath?.removePrefix("/") ?: return null
            if (uri.rawPath != "/$bot" || !botUsername.matches(bot)) return null
            val query = uri.rawQuery ?: return null
            if (!query.startsWith("start=")) return null
            val start = query.removePrefix("start=")
            // Telegram's 64-character limit includes the login/recovery prefix.
            if (start.length > 64 || !authStart.matches(start)) return null

            return TelegramAuthLink(
                value,
                "tg://resolve?domain=$bot&start=$start",
            )
        }
    }
}

internal enum class TelegramAuthLaunchResult { TELEGRAM, HTTPS_FALLBACK, FAILED }

/** Fallback is permitted only when Android has no activity for the tg handoff. */
internal object TelegramAuthLaunchPolicy {
    fun launch(
        link: TelegramAuthLink,
        launchUrl: (String) -> Unit,
        isMissingHandler: (Exception) -> Boolean,
    ): TelegramAuthLaunchResult {
        try {
            launchUrl(link.telegramUrl)
            return TelegramAuthLaunchResult.TELEGRAM
        } catch (error: Exception) {
            if (!isMissingHandler(error)) return TelegramAuthLaunchResult.FAILED
        }

        return try {
            launchUrl(link.httpsUrl)
            TelegramAuthLaunchResult.HTTPS_FALLBACK
        } catch (_: Exception) {
            TelegramAuthLaunchResult.FAILED
        }
    }
}
