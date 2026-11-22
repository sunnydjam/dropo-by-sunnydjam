package `in`.droponevedimka.dropo

import java.security.GeneralSecurityException
import javax.crypto.Cipher
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Versioned authenticated ciphertext only; no plaintext file representation. */
internal object AccountSessionEnvelope {
    const val MAX_TOKEN_BYTES = 16 * 1024
    private const val NONCE_BYTES = 12
    private const val TAG_BYTES = 16
    private val header = byteArrayOf(0x44, 0x52, 0x41, 0x53, 0x01)
    val MAX_ENCRYPTED_BYTES = header.size + NONCE_BYTES + TAG_BYTES + MAX_TOKEN_BYTES

    fun validToken(token: String): Boolean = token.isNotEmpty() &&
        token.length <= MAX_TOKEN_BYTES && token.all { it.code in 0x21..0x7e }

    fun encrypt(token: String, key: SecretKey): ByteArray {
        require(validToken(token)) { "Invalid account session token." }
        val plaintext = token.toByteArray(Charsets.US_ASCII)
        try {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            // The provider generates a fresh unpredictable IV on every write.
            cipher.init(Cipher.ENCRYPT_MODE, key)
            cipher.updateAAD(header)
            val nonce = cipher.iv
            check(nonce.size == NONCE_BYTES) { "Unsupported account session protection." }
            return header + nonce + cipher.doFinal(plaintext)
        } finally {
            plaintext.fill(0)
        }
    }

    fun decrypt(encrypted: ByteArray, key: SecretKey): String {
        if (encrypted.size !in (header.size + NONCE_BYTES + TAG_BYTES + 1)..MAX_ENCRYPTED_BYTES ||
            !encrypted.copyOfRange(0, header.size).contentEquals(header)) {
            throw GeneralSecurityException("Invalid protected account session.")
        }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        val nonce = encrypted.copyOfRange(header.size, header.size + NONCE_BYTES)
        cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(TAG_BYTES * 8, nonce))
        cipher.updateAAD(header)
        val plaintext = cipher.doFinal(encrypted, header.size + NONCE_BYTES,
            encrypted.size - header.size - NONCE_BYTES)
        try {
            if (plaintext.isEmpty() || plaintext.size > MAX_TOKEN_BYTES ||
                plaintext.any { (it.toInt() and 0xff) !in 0x21..0x7e }) {
                throw GeneralSecurityException("Invalid protected account session.")
            }
            return String(plaintext, Charsets.US_ASCII)
        } finally {
            plaintext.fill(0)
        }
    }
}
