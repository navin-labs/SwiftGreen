package com.swiftgreen.app

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey

// The AndroidKeyStore isn't on the JVM; a software AES-256 key stands in for it.
class PairingKeyVaultTest {
    private fun aes(): SecretKey = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
    private val wrap = aes()
    private val key = ByteArray(32) { (it * 7).toByte() }
    private val legacy = java.util.Base64.getEncoder().encodeToString(key)

    @Test
    fun legacyPlaintextIsMigratedToTheWrappedForm() {
        val read = PairingKeyVault.read(legacy, { wrap })
        assertArrayEquals(key, read.key)
        val sealed = read.rewrite!!
        assertTrue(sealed.startsWith("gcm1:"))
        assertTrue("the plaintext key must not survive in the new form", !sealed.contains(legacy))
        // The migrated value reads back as the same key, with nothing more to rewrite.
        val again = PairingKeyVault.read(sealed, { wrap })
        assertArrayEquals(key, again.key)
        assertNull(again.rewrite)
    }

    @Test
    fun legacyKeyIsKeptWhenSealingFails() {
        val read = PairingKeyVault.read(legacy, { throw IllegalStateException("no keystore") })
        assertArrayEquals(key, read.key)
        assertNull("nothing is written, so the legacy key stays", read.rewrite)
    }

    @Test
    fun aWrappedKeyThatCannotBeOpenedIsDeleted() {
        val sealed = PairingKeyVault.seal(key, wrap)
        // Keystore key replaced (backup restored onto a new phone): unreadable, so delete and re-pair.
        val other = PairingKeyVault.read(sealed, { aes() })
        assertNull(other.key)
        assertEquals("", other.rewrite)
        // One flipped bit fails the GCM tag the same way.
        val bytes = java.util.Base64.getDecoder().decode(sealed.removePrefix("gcm1:"))
        bytes[bytes.size - 1] = (bytes[bytes.size - 1].toInt() xor 1).toByte()
        val tampered = "gcm1:" + java.util.Base64.getEncoder().encodeToString(bytes)
        assertEquals("", PairingKeyVault.read(tampered, { wrap }).rewrite)
        assertEquals("", PairingKeyVault.read("gcm1:%%%", { wrap }).rewrite)
        assertEquals("", PairingKeyVault.read("c2hvcnQ=", { wrap }).rewrite)   // legacy of the wrong length
    }

    @Test(expected = IllegalStateException::class)
    fun anUnavailableKeystoreIsNotMistakenForAnUnreadableKey() {
        PairingKeyVault.read(PairingKeyVault.seal(key, wrap), { throw IllegalStateException("keystore busy") })
    }

    @Test
    fun nothingStoredIsUnpaired() {
        val read = PairingKeyVault.read(null, { wrap })
        assertNull(read.key)
        assertNull(read.rewrite)
    }

    @Test
    fun eachSealUsesAFreshIv() {
        assertNotEquals(PairingKeyVault.seal(key, wrap), PairingKeyVault.seal(key, wrap))
    }
}
