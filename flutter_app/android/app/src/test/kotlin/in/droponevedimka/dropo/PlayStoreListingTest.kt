package `in`.droponevedimka.dropo

import org.junit.Assert.*
import org.junit.Test

class PlayStoreListingTest {
    @Test fun documentedCanonicalTargetHasNoUndocumentedReviewParameters() {
        assertEquals("https://play.google.com/store/apps/details?id=com.dropo.myapp", PlayStoreListing.URL)
        assertEquals("com.android.vending", PlayStoreListing.STORE_PACKAGE)
    }

    @Test fun installedStoreIsPreferredWithoutOpeningABrowser() {
        var store = 0; var browser = 0
        assertTrue(PlayStoreListing.open({ store++ }, { browser++ }, { false }))
        assertEquals(1, store); assertEquals(0, browser)
    }

    @Test fun missingStoreUsesTheBrowserOnce() {
        var browser = 0
        assertTrue(PlayStoreListing.open({ throw IllegalStateException() }, { browser++ }, { true }))
        assertEquals(1, browser)
    }

    @Test fun unexpectedErrorsAndMissingBrowserAreNonfatal() {
        var browser = 0
        assertFalse(PlayStoreListing.open({ throw SecurityException() }, { browser++ }, { false }))
        assertEquals(0, browser)
        assertFalse(PlayStoreListing.open({ throw IllegalStateException() }, { throw IllegalStateException() }, { true }))
    }
}
