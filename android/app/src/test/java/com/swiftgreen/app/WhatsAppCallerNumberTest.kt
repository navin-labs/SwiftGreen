package com.swiftgreen.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class WhatsAppCallerNumberTest {
    @Test
    fun unsavedCallerTitleIsTheirNumber() {
        assertEquals("+919876543210", WhatsAppCallerNumber.numberFromTitle("+91 98765 43210"))
        assertEquals("5551234567", WhatsAppCallerNumber.numberFromTitle("(555) 123-4567"))
        // WhatsApp wraps numbers in bidi embedding marks.
        assertEquals("+14155550123", WhatsAppCallerNumber.numberFromTitle("‪+1 415-555-0123‬"))
    }

    @Test
    fun namesAndNonNumbersAreRejected() {
        assertNull(WhatsAppCallerNumber.numberFromTitle("Mum"))
        assertNull(WhatsAppCallerNumber.numberFromTitle("Acme Support Desk"))
        assertNull(WhatsAppCallerNumber.numberFromTitle("2 missed calls"))
        assertNull(WhatsAppCallerNumber.numberFromTitle("12345"))          // too short
        assertNull(WhatsAppCallerNumber.numberFromTitle("91+98765 43210"))  // '+' not leading
        assertNull(WhatsAppCallerNumber.numberFromTitle(""))
    }

    @Test
    fun contactMatchMustBeUnambiguous() {
        // Same number stored twice in different formats is still one number.
        assertEquals("+919876543210",
            WhatsAppCallerNumber.singleNumber(listOf("+91 98765 43210", "+91-98765-43210")))
        assertEquals("+919876543210",
            WhatsAppCallerNumber.singleNumber(listOf("+91 98765 43210", "098765 43210")))
        // Two different numbers under one name: don't guess.
        assertNull(WhatsAppCallerNumber.singleNumber(listOf("+91 98765 43210", "+91 91234 56789")))
        assertNull(WhatsAppCallerNumber.singleNumber(emptyList()))
    }
}
