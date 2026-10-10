package `in`.droponevedimka.dropo

import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.nio.file.Files
import java.util.concurrent.atomic.AtomicBoolean

class AndroidUpdateDownloadTest {
    private val descriptor = AndroidUpdateDescriptor(
        "3.0.44-preview", "dropo-Android-Preview-universal.apk",
        "https://github.com/sunnydjam/dropo-by-sunnydjam/releases/download/v3.0.44/dropo-Android-Preview-universal.apk", 3,
    )
    private class Connection(
        address: String,
        private val status: Int = 200,
        private val body: ByteArray = byteArrayOf(),
        private val location: String? = null,
        private val length: Long = body.size.toLong(),
    ) : HttpURLConnection(URL(address)) {
        var disconnected = false
        var responseCodeReads = 0
        override fun connect() = Unit
        override fun disconnect() { disconnected = true }
        override fun usingProxy() = false
        override fun getResponseCode(): Int {
            responseCodeReads++
            return status
        }
        override fun getInputStream() = ByteArrayInputStream(body)
        override fun getHeaderField(name: String?) = if (name == "Location") location else null
        override fun getContentLengthLong() = length
    }

    private fun rejects(action: () -> Unit) {
        try { action(); fail("Invalid download was accepted") }
        catch (_: IllegalArgumentException) { }
        catch (_: IOException) { }
    }

    @Test fun completeStreamReportsBytesAndDoesNotBufferTheWholeApk() {
        val output = ByteArrayOutputStream()
        val progress = mutableListOf<Pair<Long, Long>>()
        val downloader = AndroidUpdateDownload(AtomicBoolean(false))
        downloader.copyExact(ByteArrayInputStream("abc".toByteArray()), 3, output::write) { done, total -> progress += done to total }
        assertEquals("abc", output.toString())
        assertEquals(0L to 3L, progress.first())
        assertEquals(3L to 3L, progress.last())
    }

    @Test fun truncatedOrOversizedStreamsNeverBecomeInstallable() {
        val downloader = AndroidUpdateDownload(AtomicBoolean(false))
        for (bytes in listOf("ab", "abcd")) {
            rejects { downloader.copyExact(ByteArrayInputStream(bytes.toByteArray()), 3, {}, { _, _ -> }) }
        }
        rejects { downloader.copyExact(ByteArrayInputStream(byteArrayOf()), AndroidUpdatePolicy.MAX_APK_BYTES + 1, {}, { _, _ -> }) }
    }

    @Test fun cancellationBeforeAndDuringDownloadStopsTheStream() {
        val cancelled = AtomicBoolean(true)
        val downloader = AndroidUpdateDownload(cancelled)
        rejects { downloader.copyExact(ByteArrayInputStream("abc".toByteArray()), 3, {}, { _, _ -> }) }
        cancelled.set(false)
        rejects { downloader.copyExact(ByteArrayInputStream("abc".toByteArray()), 3, { cancelled.set(true) }, { _, _ -> }) }
    }

    @Test fun trustedGithubRedirectDownloadsAndEveryConnectionCloses() {
        val redirect = "https://release-assets.githubusercontent.com/asset?temporary=token"
        val connections = mutableListOf<Connection>()
        val downloader = AndroidUpdateDownload(AtomicBoolean(false), { url ->
            Connection(url, if (url == descriptor.downloadUrl) 302 else 200,
                if (url == redirect) "abc".toByteArray() else byteArrayOf(),
                if (url == descriptor.downloadUrl) redirect else null).also(connections::add)
        })
        val file = Files.createTempFile("dropo-stream", ".part").toFile()
        try {
            downloader.download(descriptor, file) { _, _ -> }
            assertEquals("abc", file.readText())
            assertEquals(2, connections.size)
            assertTrue(connections.all { it.disconnected && !it.instanceFollowRedirects })
        } finally { file.delete() }
    }

    @Test fun redirectToForeignHostOrHttpNeverMakesARequest() {
        for (redirect in listOf("https://evil.test/asset.apk", "http://github.com/asset.apk")) {
            val requests = mutableListOf<String>()
            val downloader = AndroidUpdateDownload(AtomicBoolean(false), { url ->
                requests += url
                Connection(url, 302, location = redirect)
            })
            rejects { downloader.checksum(descriptor) }
            assertEquals(listOf(descriptor.checksumUrl), requests)
        }
    }

    @Test fun redirectLoopsHttpFailuresAndOversizedChecksumAreActionable() {
        var requests = 0
        val loop = AndroidUpdateDownload(AtomicBoolean(false), { url -> requests++; Connection(url, 302, location = url) })
        rejects { loop.checksum(descriptor) }
        assertEquals(6, requests)
        for (status in listOf(404, 403, 500)) {
            val downloader = AndroidUpdateDownload(AtomicBoolean(false), { url -> Connection(url, status) })
            rejects { downloader.checksum(descriptor) }
        }
        val oversized = AndroidUpdateDownload(AtomicBoolean(false), { url -> Connection(url, body = ByteArray(1025)) })
        rejects { oversized.checksum(descriptor) }
    }

    @Test fun sidecarMustNameTheSelectedApkAndWrongContentLengthFails() {
        val checksum = AndroidUpdateDownload(AtomicBoolean(false), { url -> Connection(url,
            body = ("a".repeat(64) + "  " + descriptor.assetName).toByteArray()) })
        assertEquals("a".repeat(64), checksum.checksum(descriptor))
        val wrong = AndroidUpdateDownload(AtomicBoolean(false), { url -> Connection(url, body = "abc".toByteArray(), length = 4) })
        val file = Files.createTempFile("dropo-length", ".part").toFile()
        try { rejects { wrong.download(descriptor, file) { _, _ -> } } }
        finally { file.delete() }
    }

    @Test fun cancellationDuringConnectionCreationNeverContactsTheServer() {
        val cancelled = AtomicBoolean(false)
        val connection = Connection(descriptor.checksumUrl)
        val downloader = AndroidUpdateDownload(cancelled, {
            cancelled.set(true)
            connection
        })
        rejects { downloader.checksum(descriptor) }
        assertEquals(0, connection.responseCodeReads)
        assertTrue(connection.disconnected)
    }
}
