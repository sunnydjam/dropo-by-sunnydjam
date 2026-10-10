package `in`.droponevedimka.dropo

import org.junit.Assert.*
import org.junit.Test
import java.nio.file.Files

class AndroidUpdatePolicyTest {
    private val descriptor = AndroidUpdateDescriptor(
        "3.0.44-preview", "dropo-Android-Preview-universal.apk",
        "https://github.com/sunnydjam/dropo-by-sunnydjam/releases/download/v3.0.44/dropo-Android-Preview-universal.apk",
        123,
    )

    private fun rejects(action: () -> Unit) {
        try {
            action()
            fail("Unsafe update was accepted")
        } catch (_: IllegalArgumentException) {
            // Fail closed before handing any APK to Android.
        }
    }

    @Test fun installedChannelControlsExactAssetAndReleaseUrl() {
        AndroidUpdatePolicy.validateDescriptor(descriptor, "in.droponevedimka.dropo.preview")
        rejects { AndroidUpdatePolicy.validateDescriptor(descriptor, "in.droponevedimka.dropo") }
        rejects { AndroidUpdatePolicy.validateDescriptor(descriptor.copy(version = "3.0.44"), "in.droponevedimka.dropo.preview") }
        rejects { AndroidUpdatePolicy.validateDescriptor(descriptor.copy(assetName = "dropo-Android-universal.apk"), "in.droponevedimka.dropo.preview") }
        for (suffix in listOf("?download=1", "#APK", "/../other.apk")) {
            rejects { AndroidUpdatePolicy.validateDescriptor(descriptor.copy(downloadUrl = descriptor.downloadUrl + suffix), "in.droponevedimka.dropo.preview") }
        }
        rejects { AndroidUpdatePolicy.validateDescriptor(descriptor.copy(downloadUrl = descriptor.downloadUrl.replace("v3.0.44", "v3.0.43")), "in.droponevedimka.dropo.preview") }
        rejects { AndroidUpdatePolicy.validateDescriptor(descriptor.copy(size = AndroidUpdatePolicy.MAX_APK_BYTES + 1), "in.droponevedimka.dropo.preview") }
        rejects { AndroidUpdatePolicy.validateDescriptor(descriptor.copy(version = "../3.0.44-preview"), "in.droponevedimka.dropo.preview") }
    }

    @Test fun redirectsStayHttpsWithoutCredentialsOrForeignHosts() {
        for (value in listOf(
            descriptor.downloadUrl,
            "https://release-assets.githubusercontent.com/github-production-release-asset/123/file?token=temporary",
            "https://objects.githubusercontent.com/file",
        )) assertTrue(value, AndroidUpdatePolicy.isTrustedDownloadHop(value))
        for (value in listOf(
            "http://github.com/file", "https://github.com.attacker.test/file",
            "https://user:password@github.com/file", "https://github.com:444/file",
            "https://release-assets.githubusercontent.com/file#fragment",
            "file:///storage/emulated/0/file.apk", "https://evil.test/file.apk",
            "https://github.com/" + "a".repeat(16384), "not a URI",
        )) assertFalse(value, AndroidUpdatePolicy.isTrustedDownloadHop(value))
    }

    @Test fun checksumMustBeBoundedAndBelongToTheSelectedApk() {
        val digest = "a".repeat(64)
        assertEquals(digest, AndroidUpdatePolicy.parseChecksum("${digest.uppercase()}  ${descriptor.assetName}\n", descriptor.assetName))
        assertEquals(digest, AndroidUpdatePolicy.parseChecksum("$digest *${descriptor.assetName}", descriptor.assetName))
        assertEquals(digest, AndroidUpdatePolicy.parseChecksum(digest, descriptor.assetName))
        for (value in listOf("$digest other.apk", "a".repeat(63), "$digest\n$digest", "x".repeat(1025))) {
            rejects { AndroidUpdatePolicy.parseChecksum(value, descriptor.assetName) }
        }
    }

    private fun archive(
        packageName: String = "in.droponevedimka.dropo.preview",
        versionName: String = "3.0.44-preview",
        versionCode: Long = 30044,
        signer: Set<String> = setOf("installed certificate"),
        installedSigners: Set<String> = setOf("installed certificate"),
        minimumSdk: Int = 29,
        abis: Set<String> = setOf("armeabi-v7a", "arm64-v8a"),
    ) = AndroidUpdatePolicy.validateArchive(
        descriptor, "in.droponevedimka.dropo.preview", 30043, installedSigners,
        packageName, versionName, versionCode, signer, minimumSdk, 33,
        setOf("arm64-v8a", "armeabi-v7a"), abis,
    )

    @Test fun archiveGatesPackageVersionSignerSdkAndArchitectureBeforeInstall() {
        archive()
        rejects { archive(packageName = "in.droponevedimka.dropo") }
        rejects { archive(versionName = "3.0.43-preview") }
        rejects { archive(versionCode = 30043) }
        rejects { archive(versionCode = 30042) }
        rejects { archive(signer = setOf("another certificate")) }
        rejects { archive(signer = emptySet()) }
        rejects { archive(installedSigners = emptySet()) }
        rejects { archive(minimumSdk = 34) }
        rejects { archive(abis = setOf("x86_64")) }
        rejects { archive(abis = emptySet()) }
    }

    @Test fun cacheIntegrityIsRecheckedWithoutReadingWholeApkIntoMemory() {
        val file = Files.createTempFile("dropo-apk-integrity", ".apk").toFile()
        try {
            file.writeText("abc")
            assertEquals("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", AndroidUpdatePolicy.sha256(file))
            var checked = false
            AndroidUpdatePolicy.sha256(file) { checked = true }
            assertTrue(checked)
        } finally {
            file.delete()
        }
    }

    @Test fun permissionResumeCannotOpenAnInstallerAfterExpiryOrCancellation() {
        var now = 0L
        val request = AndroidUpdateRequestFence { now }
        assertTrue(request.canResume())
        now = AndroidUpdatePolicy.MAX_UPDATE_MILLIS * 1_000_000 - 1
        assertTrue(request.canResume())
        now++
        assertTrue(request.expired())
        assertFalse(request.canResume())
        val next = AndroidUpdateRequestFence { now }
        assertTrue(next.canResume())
        request.cancelled.set(true)
        assertTrue(next.canResume())
        next.cancelled.set(true)
        assertFalse(next.canResume())
    }
}
