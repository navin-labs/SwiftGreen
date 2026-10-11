package com.swiftgreen.app

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The hand-rolled HKDF must match RFC 5869 as CryptoKit computes it on the Mac
 * (hkdfDerivedSymmetricKey, empty salt, info "SwiftGreen-v1"), or no pairing completes.
 * Vector from Python's hmac with IKM = bytes 0x00..0x1f.
 */
class HkdfTest {
    @Test
    fun matchesTheSharedVector() {
        val okm = PairingManager.hkdf(ByteArray(32) { it.toByte() }, ByteArray(0), "SwiftGreen-v1".toByteArray(), 32)
        assertEquals("0c63b3717a267c7747352a06f49369af034f356e4dabdf2dae067afdd5664129",
            okm.joinToString("") { "%02x".format(it) })
    }
}
