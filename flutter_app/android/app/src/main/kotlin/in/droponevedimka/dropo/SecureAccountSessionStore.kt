package `in`.droponevedimka.dropo

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import java.io.File
import java.io.FileNotFoundException
import java.io.InputStream
import java.io.IOException
import java.security.GeneralSecurityException
import java.security.KeyStore
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey

/** Non-exportable app-UID Keystore key; ciphertext stays in noBackupFilesDir. */
internal class SecureAccountSessionStore(context: Context) {
    private val context = context.applicationContext

    private fun atomicFile(): AtomicFile =
        AtomicFile(File(context.noBackupFilesDir, "account-session.enc"))

    private fun keyStore(): KeyStore = KeyStore.getInstance("AndroidKeyStore").apply {
        load(null)
    }

    private fun existingKey(store: KeyStore): SecretKey? {
        val entry = store.getEntry(KEY_ALIAS, null) ?: return null
        return (entry as? KeyStore.SecretKeyEntry)?.secretKey
            ?: throw GeneralSecurityException("Unsupported account session key.")
    }

    private fun writeKey(): SecretKey {
        val store = keyStore()
        existingKey(store)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").run {
            init(KeyGenParameterSpec.Builder(KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setKeySize(256)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setRandomizedEncryptionRequired(true)
                .build())
            generateKey()
        }
    }

    fun read(): String? = synchronized(lock) {
        val file = atomicFile()
        val encrypted = try {
            file.openRead().use { readBounded(it) }
        } catch (error: FileNotFoundException) {
            if (ownedFiles(file).any { it.exists() }) throw error
            return@synchronized null
        }
        // Never generate a replacement key on read or accept unprotected data.
        val key = existingKey(keyStore())
            ?: throw GeneralSecurityException("Account session key is unavailable.")
        AccountSessionEnvelope.decrypt(encrypted, key)
    }

    fun write(token: String) = synchronized(lock) {
        require(AccountSessionEnvelope.validToken(token)) { "Invalid account session token." }
        // Encryption finishes before any file is opened, including AtomicFile's
        // app-private temporary file. All persisted bytes are ciphertext.
        val encrypted = AccountSessionEnvelope.encrypt(token, writeKey())
        val file = atomicFile()
        val stream = file.startWrite()
        try {
            stream.write(encrypted)
            file.finishWrite(stream)
        } catch (error: Exception) {
            file.failWrite(stream)
            throw error
        }
        val committed = file.openRead().use { readBounded(it) }
        if (!committed.contentEquals(encrypted)) {
            throw IOException("Protected account session could not be committed.")
        }
    }

    fun clear() = synchronized(lock) {
        val file = atomicFile()
        file.delete()
        if (ownedFiles(file).any { it.exists() }) {
            throw IOException("Protected account session could not be cleared.")
        }
        val store = keyStore()
        store.deleteEntry(KEY_ALIAS)
        if (store.containsAlias(KEY_ALIAS)) {
            throw GeneralSecurityException("Account session key could not be cleared.")
        }
    }

    private fun ownedFiles(file: AtomicFile): List<File> = listOf(file.baseFile,
        File(file.baseFile.path + ".new"), File(file.baseFile.path + ".bak"))

    private fun readBounded(stream: InputStream): ByteArray {
        val bytes = ByteArray(AccountSessionEnvelope.MAX_ENCRYPTED_BYTES + 1)
        var count = 0
        while (count < bytes.size) {
            val read = stream.read(bytes, count, bytes.size - count)
            if (read == -1) break
            if (read == 0) throw IOException("Protected account session read failed.")
            count += read
        }
        if (count > AccountSessionEnvelope.MAX_ENCRYPTED_BYTES) {
            throw IOException("Protected account session exceeds storage bounds.")
        }
        return bytes.copyOf(count)
    }

    companion object {
        private const val KEY_ALIAS = "dropo.account_session.v1"
        // AtomicFile requires explicit locking. Share it across activity/engine
        // recreation so writes and logout cannot race within the app process.
        private val lock = Any()
    }
}
