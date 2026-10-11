package com.swiftgreen.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Test

class RequestDedupTest {
    @Test
    fun firstSightingRuns() {
        assertSame(RequestDedup.Claim.Run, RequestDedup().claim("a"))
    }

    @Test
    fun repeatWhileRunningIsDropped() {
        val dedup = RequestDedup()
        dedup.claim("a")
        assertSame(RequestDedup.Claim.InFlight, dedup.claim("a"))
    }

    @Test
    fun repeatAfterCompletionReplaysExactResult() {
        val dedup = RequestDedup()
        dedup.claim("a")
        dedup.complete("a", "{\"type\":\"call_action_result\"}")
        assertEquals(RequestDedup.Claim.Replay("{\"type\":\"call_action_result\"}"), dedup.claim("a"))
    }

    @Test
    fun missingRequestIdIsNeverDeduped() {
        val dedup = RequestDedup()
        dedup.claim("")
        dedup.complete("", "x")
        assertSame(RequestDedup.Claim.Run, dedup.claim(""))
    }

    @Test
    fun oldestEntryIsEvictedPastCapacity() {
        val dedup = RequestDedup(capacity = 2)
        dedup.claim("a"); dedup.claim("b"); dedup.claim("c")
        assertSame(RequestDedup.Claim.Run, dedup.claim("a"))
        assertSame(RequestDedup.Claim.InFlight, dedup.claim("c"))
    }
}
