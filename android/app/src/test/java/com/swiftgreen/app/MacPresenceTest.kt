package com.swiftgreen.app

import org.junit.Assert.assertEquals
import org.junit.Test

class MacPresenceTest {
    /** Same vector as ProximityBeacon.swift gives: the two sides must agree byte for byte. */
    @Test
    fun presenceUuidMatchesMacDerivation() {
        val key = ByteArray(32) { it.toByte() }
        assertEquals("8fd2aac1-7426-8be2-53cb-49b0c99fa3cd", MacPresence.presenceUuid(key, 20000).toString())
    }

    @Test
    fun utcDayIsWholeDaysSinceEpoch() {
        assertEquals(0L, MacPresence.utcDay(86_399_999L))
        assertEquals(1L, MacPresence.utcDay(86_400_000L))
    }
}
