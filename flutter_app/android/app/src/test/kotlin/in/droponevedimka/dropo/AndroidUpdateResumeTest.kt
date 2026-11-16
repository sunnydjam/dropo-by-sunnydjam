package `in`.droponevedimka.dropo

import java.io.ByteArrayInputStream
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.nio.file.Files
import java.util.concurrent.atomic.AtomicBoolean
import org.junit.Assert.*
import org.junit.Test

class AndroidUpdateResumeTest {
    private val descriptor = AndroidUpdateDescriptor(
        "3.1.7-preview", "dropo-Android-Preview-universal.apk",
        "https://github.com/sunnydjam/dropo-by-sunnydjam/releases/download/v3.1.7/dropo-Android-Preview-universal.apk", 6,
    )
    private val checksum = "a".repeat(64)

    private class Connection(
        url: String,
        private val code: Int = 200,
        private val body: String = "abcdef",
        private val length: Long = 6,
        private val headers: Map<String, String> = emptyMap(),
    ) : HttpURLConnection(URL(url)) {
        override fun connect() = Unit
        override fun disconnect() = Unit
        override fun usingProxy() = false
        override fun getResponseCode() = code
        override fun getContentLengthLong() = length
        override fun getInputStream() = ByteArrayInputStream(body.toByteArray())
        override fun getHeaderField(name: String?) = headers[name]
    }

    private fun withPartial(block: (java.io.File) -> Unit) {
        val directory = Files.createTempDirectory("dropo-resume-test").toFile()
        try { block(java.io.File(directory, "update.part")) }
        finally { directory.listFiles()?.forEach { it.delete() }; directory.delete() }
    }

    private fun rejects(block: () -> Unit) {
        try { block(); fail("Invalid resume accepted") }
        catch (_: IllegalArgumentException) { }
        catch (_: IOException) { }
    }

    private fun seed(file: java.io.File, validator: String? = "\"release-v1\"") {
        file.writeText("abc")
        AndroidUpdateResumeStore(file, descriptor, checksum).record(validator)
    }

    @Test fun truncatedResponseResumesAtExactOffsetWithIfRangeAndCumulativeProgress() = withPartial { file ->
        val first = AndroidUpdateDownload(AtomicBoolean(false), { url ->
            Connection(url, body = "abc", headers = mapOf("ETag" to "\"release-v1\""))
        })
        rejects { first.download(descriptor, file, checksum) { _, _ -> } }
        assertEquals("abc", file.readText())
        lateinit var connection: Connection
        val resumed = AndroidUpdateDownload(AtomicBoolean(false), { url ->
            Connection(url, 206, "def", 3, mapOf("Content-Range" to "bytes 3-5/6", "ETag" to "\"release-v1\""))
                .also { connection = it }
        })
        val progress = mutableListOf<Pair<Long, Long>>()
        resumed.download(descriptor, file, checksum) { bytes, total -> progress += bytes to total }
        assertEquals("bytes=3-", connection.getRequestProperty("Range"))
        assertEquals("\"release-v1\"", connection.getRequestProperty("If-Range"))
        assertEquals("abcdef", file.readText())
        assertEquals(3L to 6L, progress.first())
        assertEquals(6L to 6L, progress.last())
    }

    @Test fun serverIgnoringRangeReplacesFileInsteadOfAppending() = withPartial { file ->
        seed(file)
        val download = AndroidUpdateDownload(AtomicBoolean(false), { Connection(it, body = "ghijkl") })
        val progress = mutableListOf<Long>()
        download.download(descriptor, file, checksum) { bytes, _ -> progress += bytes }
        assertEquals("ghijkl", file.readText())
        assertEquals(0L, progress.first())
    }

    @Test fun rangeNotSupportedRetriesOnceFromZero() = withPartial { file ->
        seed(file)
        val requests = mutableListOf<Connection>()
        val download = AndroidUpdateDownload(AtomicBoolean(false), { url ->
            Connection(url, if (requests.isEmpty()) 416 else 200).also(requests::add)
        })
        download.download(descriptor, file, checksum) { _, _ -> }
        assertEquals(2, requests.size)
        assertEquals("bytes=3-", requests[0].getRequestProperty("Range"))
        assertNull(requests[1].getRequestProperty("Range"))
        assertEquals("abcdef", file.readText())
    }

    @Test fun malformedRangesNeverAppendAndInvalidateTheSavedPart() {
        for (range in listOf(null, "bytes 0-2/6", "bytes 3-4/6", "bytes 3-5/7", "bytes 3-5/*", "bytes 999999999999999999999-5/6")) {
            withPartial { file ->
                seed(file)
                val download = AndroidUpdateDownload(AtomicBoolean(false), { url ->
                    Connection(url, 206, "def", 3, if (range == null) emptyMap() else mapOf("Content-Range" to range))
                })
                rejects { download.download(descriptor, file, checksum) { _, _ -> } }
                assertFalse(file.exists())
                assertEquals(0L, AndroidUpdateResumeStore(file, descriptor, checksum).prepare().bytes)
            }
        }
    }

    @Test fun changedValidatorAndCompressedOrOversizedResponseAreRejected() {
        for (headers in listOf(
            mapOf("Content-Range" to "bytes 3-5/6", "ETag" to "\"release-v2\""),
            mapOf("Content-Range" to "bytes 3-5/6", "Content-Encoding" to "gzip"),
        )) withPartial { file ->
            seed(file)
            val download = AndroidUpdateDownload(AtomicBoolean(false), { Connection(it, 206, "def", 3, headers) })
            rejects { download.download(descriptor, file, checksum) { _, _ -> } }
            assertFalse(file.exists())
        }
        withPartial { file ->
            seed(file)
            val download = AndroidUpdateDownload(AtomicBoolean(false), { Connection(it, 206, "defg", 3, mapOf("Content-Range" to "bytes 3-5/6")) })
            rejects { download.download(descriptor, file, checksum) { _, _ -> } }
            assertFalse(file.exists())
        }
    }

    @Test fun transientHttpFailureKeepsBoundPartialFile() = withPartial { file ->
        seed(file)
        val download = AndroidUpdateDownload(AtomicBoolean(false), { Connection(it, 503) })
        rejects { download.download(descriptor, file, checksum) { _, _ -> } }
        assertEquals("abc", file.readText())
        assertEquals(3L, AndroidUpdateResumeStore(file, descriptor, checksum).prepare().bytes)
    }

    @Test fun explicitCancelClearsButDeadlineOrActivityClosureKeepsPartial() {
        for (keep in listOf(false, true)) withPartial { file ->
            seed(file)
            val download = AndroidUpdateDownload(AtomicBoolean(false), { error("No HTTP after cancellation") })
            download.cancel(keepPartial = keep)
            rejects { download.download(descriptor, file, checksum) { _, _ -> } }
            assertEquals(keep, file.exists())
        }
    }

    @Test fun fullCachedPartDoesNotDownloadButStillNeedsFullChecksumVerification() = withPartial { file ->
        seed(file)
        file.writeText("abcdef")
        val download = AndroidUpdateDownload(AtomicBoolean(false), { error("No HTTP for complete cache") })
        download.download(descriptor, file, checksum) { bytes, total -> assertEquals(total, bytes) }
        // Updater always performs this exact full-file verification, even for complete cache.
        assertNotEquals(checksum, AndroidUpdatePolicy.sha256(file))
    }

    @Test fun changingAnyReleaseIdentityOrExpectedHashInvalidatesCache() {
        for (changed in listOf(
            descriptor.copy(version = "3.1.8-preview"), descriptor.copy(assetName = "dropo-Android-Preview-arm64.apk"),
            descriptor.copy(downloadUrl = descriptor.downloadUrl + "?different"), descriptor.copy(size = 7),
        )) withPartial { file ->
            seed(file)
            assertEquals(0L, AndroidUpdateResumeStore(file, changed, checksum).prepare().bytes)
            assertFalse(file.exists())
        }
        withPartial { file ->
            seed(file)
            assertEquals(0L, AndroidUpdateResumeStore(file, descriptor, "b".repeat(64)).prepare().bytes)
        }
    }

    @Test fun expiredCorruptAndOversizedCacheAreDiscarded() = withPartial { file ->
        seed(file)
        file.setLastModified(System.currentTimeMillis() - 8L * 24 * 60 * 60 * 1000)
        assertEquals(0L, AndroidUpdateResumeStore(file, descriptor, checksum).prepare().bytes)
        seed(file)
        java.io.File(file.parentFile, file.name + ".resume").writeText("bad metadata")
        assertEquals(0L, AndroidUpdateResumeStore(file, descriptor, checksum).prepare().bytes)
        seed(file)
        file.writeText("oversized")
        assertEquals(0L, AndroidUpdateResumeStore(file, descriptor, checksum).prepare().bytes)
    }

    @Test fun weakOrUnsafeValidatorsAreNeverSentAsRequestHeaders() {
        for (validator in listOf("W/\"weak\"", "\"tag\"\r\nHost: evil.test", "not-quoted")) {
            assertNull(AndroidUpdateResumeStore.strongETag(validator))
        }
        withPartial { file ->
            seed(file, "W/\"weak\"")
            assertNull(AndroidUpdateResumeStore(file, descriptor, checksum).prepare().validator)
        }
    }
}
