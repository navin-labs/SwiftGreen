package com.swiftgreen.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Test
import java.io.IOException
import java.io.Reader
import java.io.StringReader

class LineReaderTest {
    @Test
    fun readsLinesLikeBufferedReader() {
        val r = LineReader(StringReader("{\"type\":\"challenge\"}\nsecond\r\n\nlast-no-newline"))
        assertEquals("{\"type\":\"challenge\"}", r.readLine())
        assertEquals("second", r.readLine())
        assertEquals("", r.readLine())
        assertEquals("last-no-newline", r.readLine())
        assertNull(r.readLine())
    }

    @Test
    fun linesSplitAcrossReadsAreJoined() {
        // One char per read(), as a slow socket might deliver it.
        val slow = object : Reader() {
            val src = StringReader("a".repeat(20_000) + "\nb\n")
            override fun read(cbuf: CharArray, off: Int, len: Int) = src.read(cbuf, off, 1)
            override fun close() {}
        }
        val r = LineReader(slow)
        assertEquals(20_000, r.readLine()!!.length)
        assertEquals("b", r.readLine())
    }

    // A host that answers on the Mac's port and never sends a newline used to grow the
    // phone's buffer until it ran out of memory, before any authentication.
    @Test
    fun endlessLineBeforeAuthIsRefused() {
        val endless = object : Reader() {
            override fun read(cbuf: CharArray, off: Int, len: Int): Int { cbuf.fill('A', off, off + len); return len }
            override fun close() {}
        }
        assertThrows(IOException::class.java) { LineReader(endless).readLine() }
    }

    @Test
    fun limitIsRaisedAfterAuth() {
        val big = "x".repeat(LineReader.BEFORE_AUTH + 1)
        assertThrows(IOException::class.java) { LineReader(StringReader("$big\n")).readLine() }
        val r = LineReader(StringReader("$big\n"))
        r.limit = LineReader.AFTER_AUTH
        assertEquals(big, r.readLine())
    }

    @Test
    fun exactlyAtLimitIsAccepted() {
        val atLimit = "y".repeat(LineReader.BEFORE_AUTH)
        assertEquals(atLimit, LineReader(StringReader("$atLimit\n")).readLine())
    }
}
