package `in`.droponevedimka.dropo

import org.junit.Assert.*
import org.junit.Test

class TelegramAuthLinkTest {
    private val loginUrl = "https://t.me/DropoTest_bot?start=login_Abc123_-xyz"
    private class MissingHandler : RuntimeException()

    @Test fun loginAndRecoveryPreserveTheExactStartPayload() {
        for (prefix in listOf("login_", "recover_")) {
            val start = "${prefix}Abc123_-xyz"
            val httpsUrl = "https://t.me/DropoTest_bot?start=$start"
            val link = TelegramAuthLink.fromHttps(httpsUrl)!!
            assertEquals(httpsUrl, link.httpsUrl)
            assertEquals("tg://resolve?domain=DropoTest_bot&start=$start", link.telegramUrl)
        }
    }

    @Test fun acceptsOnlyTheDefaultHttpsPortAndValidBotUsernameBounds() {
        for (bot in listOf("Abc_1", "A" + "b".repeat(31))) {
            for (authority in listOf("t.me", "t.me:443")) {
                assertNotNull(TelegramAuthLink.fromHttps("https://$authority/$bot?start=login_a"))
            }
        }
        for (bot in listOf("Abcd", "A" + "b".repeat(32), "1Abcd", "_Abcd", "Abc-d", "Ботик")) {
            assertNull(bot, TelegramAuthLink.fromHttps("https://t.me/$bot?start=login_a"))
        }
    }

    @Test fun startLimitIncludesThePrefixAndRequiresAnUnpaddedBase64UrlChallenge() {
        for (prefix in listOf("login_", "recover_")) {
            val boundary = prefix + "a".repeat(64 - prefix.length)
            assertNotNull(TelegramAuthLink.fromHttps("https://t.me/DropoTest_bot?start=$boundary"))
            assertNull(TelegramAuthLink.fromHttps("https://t.me/DropoTest_bot?start=${boundary}a"))
        }
        for (start in listOf("login_", "recover_", "login_a=", "login_a+b", "login_a/b", "login_a%2Db", "other_abc")) {
            assertNull(start, TelegramAuthLink.fromHttps("https://t.me/DropoTest_bot?start=$start"))
        }
    }

    @Test fun invalidOrOrdinaryUrlsAreNotIntercepted() {
        for (url in listOf(
            "http://t.me/DropoTest_bot?start=login_a",
            "https://t.me.attacker.test/DropoTest_bot?start=login_a",
            "https://t.me./DropoTest_bot?start=login_a",
            "https://user@t.me/DropoTest_bot?start=login_a",
            "https://t.me:444/DropoTest_bot?start=login_a",
            "https://t.me:/DropoTest_bot?start=login_a",
            "$loginUrl#fragment",
            "$loginUrl&start=login_duplicate",
            "$loginUrl&extra=1",
            "$loginUrl&",
            "https://t.me/DropoTest_bot?extra=1&start=login_a",
            "https://t.me/DropoTest_bot?%73tart=login_a",
            "https://t.me/DropoTest_bot/?start=login_a",
            "https://t.me/DropoTest_bot/123?start=login_a",
            "https://t.me/%44ropoTest_bot?start=login_a",
            "https://t.me/DropoTest_bot?startgroup=login_a",
            "https://t.me/DropoTest_bot?start=promo",
            "https://t.me/DropoTest_bot",
            "tg://resolve?domain=DropoTest_bot&start=login_a",
            "https://example.test/path",
            "not a URI",
            "https://t.me/" + "a".repeat(257),
        )) assertNull(url, TelegramAuthLink.fromHttps(url))
    }

    @Test fun launchesTelegramFirstWithoutLaunchingHttpsAfterSuccess() {
        val link = TelegramAuthLink.fromHttps(loginUrl)!!
        val opened = mutableListOf<String>()
        val outcome = TelegramAuthLaunchPolicy.launch(link, { opened.add(it) }, { it is MissingHandler })
        assertEquals(TelegramAuthLaunchResult.TELEGRAM, outcome)
        assertEquals(listOf(link.telegramUrl), opened)
    }

    @Test fun absentTelegramFallsBackToTheSameHttpsChallengeExactlyOnce() {
        val link = TelegramAuthLink.fromHttps(loginUrl)!!
        val opened = mutableListOf<String>()
        val outcome = TelegramAuthLaunchPolicy.launch(link, {
            opened.add(it)
            if (it.startsWith("tg:")) throw MissingHandler()
        }, { it is MissingHandler })
        assertEquals(TelegramAuthLaunchResult.HTTPS_FALLBACK, outcome)
        assertEquals(listOf(link.telegramUrl, loginUrl), opened)
    }

    @Test fun permissionAndUnexpectedErrorsDoNotTriggerHttpsFallback() {
        val link = TelegramAuthLink.fromHttps(loginUrl)!!
        for (error in listOf(SecurityException("private auth detail"), IllegalStateException("private auth detail"))) {
            val opened = mutableListOf<String>()
            val outcome = TelegramAuthLaunchPolicy.launch(link, {
                opened.add(it)
                throw error
            }, { it is MissingHandler })
            assertEquals(TelegramAuthLaunchResult.FAILED, outcome)
            assertEquals(listOf(link.telegramUrl), opened)
        }
    }

    @Test fun failedHttpsFallbackIsReportedWithoutRetryingAnotherHandler() {
        val link = TelegramAuthLink.fromHttps(loginUrl)!!
        val opened = mutableListOf<String>()
        val outcome = TelegramAuthLaunchPolicy.launch(link, {
            opened.add(it)
            if (it.startsWith("tg:")) throw MissingHandler()
            throw SecurityException("private auth detail")
        }, { it is MissingHandler })
        assertEquals(TelegramAuthLaunchResult.FAILED, outcome)
        assertEquals(listOf(link.telegramUrl, loginUrl), opened)
    }

    @Test fun delegatesMultipleClientSelectionToThePlatformWithoutFixingAPackage() {
        val link = TelegramAuthLink.fromHttps(loginUrl)!!
        val opened = mutableListOf<String>()
        // The callback is the platform resolver: the policy only supplies a URI,
        // so the user's preferred Telegram client/chooser remains authoritative.
        val outcome = TelegramAuthLaunchPolicy.launch(link, { opened.add(it) }, { false })
        assertEquals(TelegramAuthLaunchResult.TELEGRAM, outcome)
        assertEquals("tg://resolve?domain=DropoTest_bot&start=login_Abc123_-xyz", opened.single())
        assertFalse(opened.single().contains("package="))
    }
}
