package com.swiftgreen.app

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MacCertPinTest {
    private val key = ByteArray(32) { it.toByte() }
    private val clientNonce = ByteArray(32) { 7 }
    private val cert = MacCertPin.fingerprint("cert".toByteArray())
    private val otherCert = MacCertPin.fingerprint("another cert".toByteArray())
    private fun b64(b: ByteArray) = java.util.Base64.getEncoder().encodeToString(b)
    private fun hex(b: ByteArray) = b.joinToString("") { "%02x".format(it) }

    @Test
    fun idProofMatchesTheDocumentedFormula() {
        // HMAC-SHA256(K, "SwiftGreen-tls-id|" ‖ C ‖ F), computed independently; the Mac's
        // mDNSQuicServer.challengeOK must produce the same bytes.
        assertEquals("06298432e8066b29e2223bcc23aa9504b56ae508fabf3435508869b9c3190e22", hex(cert))
        assertEquals("6acfada117ce6bc40786d440d1f80c64363d7da65dd9a0408f7ae1883b9545ce",
            hex(MacCertPin.idProof(key, clientNonce, cert)))
    }

    @Test
    fun aProvenClaimForThisConnectionsCertificateIsConfirmed() {
        val v = MacCertPin.evaluate(key, clientNonce, cert, b64(cert), b64(MacCertPin.idProof(key, clientNonce, cert)))
        assertTrue(v is MacCertPin.Verdict.Confirmed)
        assertArrayEquals(cert, (v as MacCertPin.Verdict.Confirmed).fingerprint)
    }

    @Test
    fun aRelayPresentingItsOwnCertificateIsRejected() {
        // The real Mac proves its certificate, but the phone is talking to a relay's.
        val v = MacCertPin.evaluate(key, clientNonce, otherCert, b64(cert), b64(MacCertPin.idProof(key, clientNonce, cert)))
        assertEquals(MacCertPin.Verdict.Rejected, v)
    }

    @Test
    fun aClaimWithoutTheKeyIsRejected() {
        val wrongKey = ByteArray(32) { 1 }
        val v = MacCertPin.evaluate(key, clientNonce, cert, b64(cert), b64(MacCertPin.idProof(wrongKey, clientNonce, cert)))
        assertEquals(MacCertPin.Verdict.Rejected, v)
        // A proof replayed from another connection (another client nonce) doesn't verify either.
        val replay = MacCertPin.idProof(key, ByteArray(32) { 9 }, cert)
        assertEquals(MacCertPin.Verdict.Rejected, MacCertPin.evaluate(key, clientNonce, cert, b64(cert), b64(replay)))
    }

    @Test
    fun anOlderMacMakesNoClaim() {
        assertEquals(MacCertPin.Verdict.Unclaimed, MacCertPin.evaluate(key, clientNonce, cert, "", ""))
        assertEquals(MacCertPin.Verdict.Unclaimed, MacCertPin.evaluate(key, clientNonce, cert, null, null))
    }

    @Test
    fun malformedClaimsAreRejectedNotCrashes() {
        assertEquals(MacCertPin.Verdict.Rejected, MacCertPin.evaluate(key, clientNonce, cert, "not base64!", "x"))
        assertEquals(MacCertPin.Verdict.Rejected, MacCertPin.evaluate(key, clientNonce, cert, b64(ByteArray(5)), b64(ByteArray(32))))
        assertEquals(MacCertPin.Verdict.Rejected, MacCertPin.evaluate(key, clientNonce, null, b64(cert),
            b64(MacCertPin.idProof(key, clientNonce, cert))))
    }

    @Test
    fun decodeAcceptsOnlyAFullFingerprint() {
        assertArrayEquals(cert, MacCertPin.decode(b64(cert)))
        assertNull(MacCertPin.decode(b64(ByteArray(31))))
        assertNull(MacCertPin.decode(""))
        assertNull(MacCertPin.decode(null))
        assertNull(MacCertPin.decode("%%%"))
    }

    @Test
    fun matchesNeedsTheSameCertificate() {
        assertTrue(MacCertPin.matches(cert, cert.copyOf()))
        assertFalse(MacCertPin.matches(otherCert, cert))
        assertFalse(MacCertPin.matches(null, cert))
    }
}
