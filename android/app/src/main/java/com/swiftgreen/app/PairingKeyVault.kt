package com.swiftgreen.app

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * The pairing key at rest (SG-07): AES-256-GCM under a non-exportable AndroidKeyStore key,
 * so a copy of `swiftgreen_pairing.xml` alone no longer yields the key. It does not help
 * against code running as this app, or a rooted phone that can use the Keystore key.
 *
 * Stored form: "gcm1:" + base64(iv ‖ ciphertext ‖ tag). A bare base64 value is the
 * plaintext key every build before this one wrote; [classify] reports it as [Stored.Legacy]
 * and the caller re-seals it.
 */
object PairingKeyVault {
    const val ALIAS = "swiftgreen_pairing_wrap"
    private const val PREFIX = "gcm1:"
    private const val KEY_BYTES = 32
    private val AAD = "SwiftGreen-pairing-key".toByteArray(Charsets.UTF_8)

    sealed class Stored {
        object None : Stored()
        class Legacy(val key: ByteArray) : Stored()
        class Wrapped(val key: ByteArray) : Stored()
        /** Present but can't be opened: Keystore key gone (restore, new phone) or the value damaged. */
        object Unreadable : Stored()
    }

    fun seal(key: ByteArray, wrapKey: SecretKey): String {
        require(key.size == KEY_BYTES)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, wrapKey)   // the provider picks a fresh random IV
        cipher.updateAAD(AAD)
        return PREFIX + java.util.Base64.getEncoder().encodeToString(cipher.iv + cipher.doFinal(key))
    }

    fun classify(stored: String?, wrapKey: () -> SecretKey): Stored {
        if (stored.isNullOrEmpty()) return Stored.None
        if (!stored.startsWith(PREFIX)) {
            val legacy = runCatching { java.util.Base64.getDecoder().decode(stored) }.getOrNull()
            return if (legacy?.size == KEY_BYTES) Stored.Legacy(legacy) else Stored.Unreadable
        }
        // Outside runCatching: a Keystore that is unavailable right now throws to the caller,
        // which must not read that as "unreadable" and delete a good key.
        val unwrapKey = wrapKey()
        return runCatching {
            val blob = java.util.Base64.getDecoder().decode(stored.removePrefix(PREFIX))
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, unwrapKey, GCMParameterSpec(128, blob, 0, 12))
            cipher.updateAAD(AAD)
            cipher.doFinal(blob, 12, blob.size - 12)
        }.getOrNull()?.takeIf { it.size == KEY_BYTES }?.let { Stored.Wrapped(it) } ?: Stored.Unreadable
    }

    /** The key to use (null = unpaired) and what to write back: null = nothing, "" = delete, else the sealed form. */
    class Read(val key: ByteArray?, val rewrite: String?)

    /** Opens [stored]; a legacy plaintext key is re-sealed (kept as is if sealing fails), an unreadable one deleted. */
    fun read(stored: String?, wrapKey: () -> SecretKey): Read = when (val s = classify(stored, wrapKey)) {
        Stored.None -> Read(null, null)
        is Stored.Wrapped -> Read(s.key, null)
        is Stored.Legacy -> Read(s.key, runCatching { seal(s.key, wrapKey()) }.getOrNull())
        Stored.Unreadable -> Read(null, "")
    }

    /** This install's AndroidKeyStore wrapping key, created on first use. */
    fun keystoreKey(): SecretKey = synchronized(this) {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (ks.getKey(ALIAS, null) as? SecretKey) ?: KeyGenerator
            .getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
            .apply {
                init(KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setKeySize(256)
                    .build())
            }.generateKey()
    }
}
