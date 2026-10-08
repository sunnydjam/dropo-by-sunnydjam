package `in`.droponevedimka.dropo

import java.security.GeneralSecurityException
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import org.junit.Assert.*
import org.junit.Test

class AccountSessionEnvelopeTest {
    private val token = "synthetic-only.account-session_123456789"
    private fun key(): SecretKey = KeyGenerator.getInstance("AES").run {
        init(256)
        generateKey()
    }

    @Test fun protectedRoundTripContainsNoPlaintext() {
        val key = key()
        val encrypted = AccountSessionEnvelope.encrypt(token, key)
        assertEquals(token, AccountSessionEnvelope.decrypt(encrypted, key))
        assertFalse(String(encrypted, Charsets.ISO_8859_1).contains(token))
    }

    @Test fun everyWriteGetsFreshNonceAndCiphertext() {
        val key = key()
        val first = AccountSessionEnvelope.encrypt(token, key)
        val second = AccountSessionEnvelope.encrypt(token, key)
        assertFalse(first.copyOfRange(5, 17).contentEquals(second.copyOfRange(5, 17)))
        assertFalse(first.contentEquals(second))
        assertEquals(token, AccountSessionEnvelope.decrypt(first, key))
        assertEquals(token, AccountSessionEnvelope.decrypt(second, key))
    }

    @Test fun maximumBoundedTokenRoundTrips() {
        val key = key()
        val maximum = "a".repeat(AccountSessionEnvelope.MAX_TOKEN_BYTES)
        val encrypted = AccountSessionEnvelope.encrypt(maximum, key)
        assertEquals(AccountSessionEnvelope.MAX_ENCRYPTED_BYTES, encrypted.size)
        assertEquals(maximum, AccountSessionEnvelope.decrypt(encrypted, key))
    }

    @Test fun invalidTokensNeverReachCipher() {
        val key = key()
        for (invalid in listOf("", " leading", "trailing ", "contains space",
            "line\nbreak", "null\u0000byte", "del\u007fbyte", "non-ascii-é",
            "x".repeat(AccountSessionEnvelope.MAX_TOKEN_BYTES + 1))) {
            assertFalse(AccountSessionEnvelope.validToken(invalid))
            try {
                AccountSessionEnvelope.encrypt(invalid, key)
                fail("Invalid token accepted")
            } catch (_: IllegalArgumentException) { }
        }
    }

    private fun assertRejected(encrypted: ByteArray, key: SecretKey) {
        try {
            AccountSessionEnvelope.decrypt(encrypted, key)
            fail("Unauthenticated ciphertext accepted")
        } catch (_: GeneralSecurityException) { }
    }

    @Test fun modifiedVersionIsRejected() {
        val key = key()
        val encrypted = AccountSessionEnvelope.encrypt(token, key)
        encrypted[4] = 2
        assertRejected(encrypted, key)
    }

    @Test fun modifiedNonceIsRejected() {
        val key = key()
        val encrypted = AccountSessionEnvelope.encrypt(token, key)
        encrypted[5] = (encrypted[5].toInt() xor 1).toByte()
        assertRejected(encrypted, key)
    }

    @Test fun modifiedCiphertextIsRejected() {
        val key = key()
        val encrypted = AccountSessionEnvelope.encrypt(token, key)
        encrypted[17] = (encrypted[17].toInt() xor 1).toByte()
        assertRejected(encrypted, key)
    }

    @Test fun modifiedAuthenticationTagIsRejected() {
        val key = key()
        val encrypted = AccountSessionEnvelope.encrypt(token, key)
        encrypted[encrypted.lastIndex] = (encrypted.last().toInt() xor 1).toByte()
        assertRejected(encrypted, key)
    }

    @Test fun truncatedAndOversizedFilesAreRejected() {
        val key = key()
        val encrypted = AccountSessionEnvelope.encrypt(token, key)
        assertRejected(byteArrayOf(), key)
        assertRejected(encrypted.copyOf(17), key)
        assertRejected(encrypted.copyOf(encrypted.size - 1), key)
        assertRejected(ByteArray(AccountSessionEnvelope.MAX_ENCRYPTED_BYTES + 1), key)
    }

    @Test fun differentKeyCannotReadSession() {
        assertRejected(AccountSessionEnvelope.encrypt(token, key()), key())
    }
}
