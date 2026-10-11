package com.swiftgreen.app

import java.security.MessageDigest
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/**
 * The paired Mac's TLS certificate, pinned by SHA-256 (SG-09, PROTOCOL.md).
 *
 * Each Mac install has its own certificate. The phone learns its fingerprint either from
 * the pairing QR (checked against the certificate the pairing connection presents) or,
 * for a phone paired before that existed, from `challenge-ok` on a connection where the
 * Mac proved the pairing key: `tls_id` plus HMAC(K, "SwiftGreen-tls-id|" ‖ client_nonce ‖
 * tls_id). Once pinned, a host presenting any other certificate is never sent anything.
 */
object MacCertPin {
    const val FINGERPRINT_BYTES = 32

    fun fingerprint(certificateDer: ByteArray): ByteArray =
        MessageDigest.getInstance("SHA-256").digest(certificateDer)

    fun matches(seen: ByteArray?, pinned: ByteArray): Boolean =
        seen != null && MessageDigest.isEqual(seen, pinned)

    /** The fingerprint from a QR or message field, or null when absent or malformed. */
    fun decode(base64: String?): ByteArray? {
        if (base64.isNullOrEmpty()) return null
        return runCatching { java.util.Base64.getDecoder().decode(base64) }.getOrNull()
            ?.takeIf { it.size == FINGERPRINT_BYTES }
    }

    sealed class Verdict {
        /** The Mac sent no certificate claim (a Mac from before per-install identities). */
        object Unclaimed : Verdict()
        /** Proven by the pairing key and equal to this connection's certificate. */
        class Confirmed(val fingerprint: ByteArray) : Verdict()
        /** A claim that doesn't verify, or names a certificate other than this connection's. */
        object Rejected : Verdict()
    }

    /**
     * Checks `challenge-ok`'s certificate claim. [seen] is the fingerprint of the
     * certificate on this connection; [clientNonce] is the nonce this phone just sent.
     */
    fun evaluate(key: ByteArray, clientNonce: ByteArray, seen: ByteArray?,
                 tlsIdBase64: String?, proofBase64: String?): Verdict {
        if (tlsIdBase64.isNullOrEmpty() && proofBase64.isNullOrEmpty()) return Verdict.Unclaimed
        val tlsId = decode(tlsIdBase64) ?: return Verdict.Rejected
        val proof = runCatching { java.util.Base64.getDecoder().decode(proofBase64 ?: "") }.getOrNull()
            ?: return Verdict.Rejected
        val expected = idProof(key, clientNonce, tlsId)
        if (!MessageDigest.isEqual(proof, expected)) return Verdict.Rejected
        return if (matches(seen, tlsId)) Verdict.Confirmed(tlsId) else Verdict.Rejected
    }

    /** HMAC(K, "SwiftGreen-tls-id|" ‖ client_nonce ‖ fingerprint); the Mac's challengeOK builds the same. */
    fun idProof(key: ByteArray, clientNonce: ByteArray, fingerprint: ByteArray): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key, "HmacSHA256"))
        mac.update("SwiftGreen-tls-id|".toByteArray(Charsets.UTF_8))
        mac.update(clientNonce)
        return mac.doFinal(fingerprint)
    }
}
