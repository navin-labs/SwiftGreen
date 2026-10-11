package com.swiftgreen.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

/**
 * The unpair proof must be byte-identical on the phone and the Mac
 * (PairingManager.unpairProof in PairingManager.swift): HMAC-SHA256(K, "SwiftGreen-unpaired").
 * The vector was computed independently: Python's hmac with K = bytes 0x00..0x1f.
 */
class UnpairProofTest {
    private fun hex(b: ByteArray) = b.joinToString("") { "%02x".format(it) }

    @Test
    fun matchesTheSharedVector() {
        val key = ByteArray(32) { it.toByte() }
        assertEquals("f3c964442808f6b63f3176acab49d0f8b48bd8542fc2ad2789ab2f8acd2669a2",
            hex(PairingManager.unpairProof(key)))
    }

    @Test
    fun differsPerPairing() {
        val a = PairingManager.unpairProof(ByteArray(32) { 1 })
        val b = PairingManager.unpairProof(ByteArray(32) { 2 })
        assertFalse(a.contentEquals(b))
    }
}
