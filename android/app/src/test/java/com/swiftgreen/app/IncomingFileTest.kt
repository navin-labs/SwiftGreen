package com.swiftgreen.app

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.OutputStream
import java.security.MessageDigest

class IncomingFileTest {
    private class FakeSink(private val failWrites: Boolean = false, private val publishTo: String? = "content://x/1") : ReceiveSink {
        val bytes = ByteArrayOutputStream()
        var published = false
        var discarded = false
        override val out: OutputStream = object : OutputStream() {
            override fun write(b: Int) { if (failWrites) throw IOException("disk full"); bytes.write(b) }
        }
        override fun publish(): String? { published = true; return publishTo }
        override fun discard() { discarded = true }
    }

    private val body = "hello world".toByteArray()
    private val sha = MessageDigest.getInstance("SHA-256").digest(body).joinToString("") { "%02x".format(it) }

    @Test
    fun aCompleteFileWithTheRightChecksumIsPublished() {
        val sink = FakeSink()
        val f = IncomingFile(sink, 2, body.size.toLong(), sha)
        assertTrue(f.accept(0, body.copyOfRange(0, 5)))
        assertTrue(f.accept(0, body.copyOfRange(0, 5)))   // a replay is skipped, not written twice
        assertTrue(f.accept(1, body.copyOfRange(5, body.size)))
        assertEquals("content://x/1", f.finish())
        assertArrayEquals(body, sink.bytes.toByteArray())
        assertFalse(sink.discarded)
    }

    @Test
    fun aChecksumMismatchIsDiscardedNeverPublished() {
        val sink = FakeSink()
        val f = IncomingFile(sink, 1, body.size.toLong(), "0".repeat(64))
        assertTrue(f.accept(0, body))
        assertNull(f.finish())
        assertTrue(sink.discarded)
        assertFalse(sink.published)
        // No checksum at all is a mismatch too, not a pass.
        val s2 = FakeSink()
        IncomingFile(s2, 1, body.size.toLong(), "").apply { accept(0, body); assertNull(finish()) }
        assertTrue(s2.discarded)
    }

    @Test
    fun incompleteGapsAndWriteFailuresAreFatal() {
        val short = FakeSink()
        IncomingFile(short, 2, body.size.toLong(), sha).apply { accept(0, body); assertNull(finish()) }
        assertTrue("a missing chunk is discarded", short.discarded)

        assertFalse("a gap is fatal", IncomingFile(FakeSink(), 3, 0, sha).accept(1, body))
        assertFalse("a failed write is fatal", IncomingFile(FakeSink(failWrites = true), 1, 0, sha).accept(0, body))

        val unpublishable = FakeSink(publishTo = null)
        IncomingFile(unpublishable, 1, body.size.toLong(), sha).apply { accept(0, body); assertNull(finish()) }
        assertTrue(unpublishable.discarded)
    }

    @Test
    fun freeNameNeverReusesATakenName() {
        val taken = setOf("a.txt", "a_1.txt", "noext")
        assertEquals("b.txt", freeDownloadName("b.txt") { it in taken })
        assertEquals("a_2.txt", freeDownloadName("a.txt") { it in taken })
        assertEquals("noext_1", freeDownloadName("noext") { it in taken })
        assertNull("all 100 names taken: refuse rather than overwrite", freeDownloadName("a.txt") { true })
    }
}
