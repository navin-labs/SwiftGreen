package com.swiftgreen.app

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SmsPartTallyTest {
    @Test
    fun singlePartReportsItsResult() {
        assertTrue(SmsPartTally().onPart(ok = true))
        assertTrue(SmsPartTally().onPart(ok = false))
    }

    @Test
    fun multipartSucceedsOnlyWhenEveryPartIsSent() {
        val t = SmsPartTally().apply { expect(3) }
        assertFalse(t.onPart(true))
        assertFalse(t.onPart(true))
        assertTrue(t.onPart(true))
        assertFalse(t.timeout())           // outcome already known: no provisional answer
        assertFalse(t.claim())             // and nothing left to give up on
    }

    @Test
    fun firstFailedPartReportsAndLaterPartsAreIgnored() {
        val t = SmsPartTally().apply { expect(3) }
        assertFalse(t.onPart(true))
        assertTrue(t.onPart(false))
        assertFalse(t.onPart(true))
        assertFalse(t.claim())
    }

    @Test
    fun isFinalOnlyAfterAnOutcome() {
        val t = SmsPartTally().apply { expect(2) }
        assertFalse(t.isFinal())
        assertFalse(t.onPart(true))        // one part of two: still going
        assertFalse(t.isFinal())
        assertTrue(t.onPart(true))
        assertTrue(t.isFinal())              // the provider watcher stops here
    }

    @Test
    fun providerClaimAfterPartialPartsEndsIt() {
        val t = SmsPartTally().apply { expect(3) }
        assertFalse(t.onPart(true))        // part 1 reported, parts 2-3 never do
        assertTrue(t.claim())              // the provider row wins
        assertTrue(t.isFinal())
        assertFalse(t.onPart(true))
    }

    @Test
    fun lateResultAfterTimeoutIsStillReportedOnce() {
        val t = SmsPartTally().apply { expect(2) }
        assertFalse(t.onPart(true))
        assertTrue(t.timeout())            // provisional answer at 15 s
        assertFalse(t.timeout())           // only once
        assertTrue(t.onPart(true))         // the real outcome still goes out
        assertFalse(t.onPart(false))
        assertFalse(t.claim())
    }

    @Test
    fun giveUpAfterTimeoutStopsLateParts() {
        val t = SmsPartTally()
        assertTrue(t.timeout())
        assertTrue(t.claim())              // final wait ran out
        assertFalse(t.onPart(true))
    }

    @Test
    fun sendExceptionClaimsBeforeAnyPart() {
        val t = SmsPartTally()
        assertTrue(t.claim())
        assertFalse(t.timeout())
        assertFalse(t.onPart(false))
    }
}
