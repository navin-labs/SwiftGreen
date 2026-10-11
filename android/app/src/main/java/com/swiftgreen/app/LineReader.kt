package com.swiftgreen.app

import java.io.IOException
import java.io.Reader

/**
 * BufferedReader.readLine with a ceiling. readLine grows its buffer until a newline
 * arrives, so anything answering on the Mac's port that never sends one — before the
 * challenge proves it is the Mac — could run the phone out of memory. Over [limit]
 * chars it throws, which every read loop already treats as a dropped connection.
 * Lines end at '\n' (what the Mac sends); a trailing '\r' is dropped.
 */
class LineReader(private val reader: Reader, @Volatile var limit: Int = BEFORE_AUTH) {
    private val buf = CharArray(8192)
    private var pos = 0
    private var end = 0

    fun readLine(): String? {
        val line = StringBuilder()
        while (true) {
            if (pos == end) {
                val n = reader.read(buf, 0, buf.size)
                if (n < 0) return if (line.isEmpty()) null else line.toString()
                pos = 0
                end = n
            }
            var i = pos
            while (i < end && buf[i] != '\n') i++
            if (line.length + (i - pos) > limit) throw IOException("Line over $limit chars — closing")
            line.appendRange(buf, pos, i)
            if (i < end) {
                pos = i + 1
                if (line.endsWith('\r')) line.setLength(line.length - 1)
                return line.toString()
            }
            pos = end
        }
    }

    companion object {
        /** Handshake lines are tiny. */
        const val BEFORE_AUTH = 64 * 1024
        /** Same ceiling as the Mac's (mDNSQuicServer.maxBufferedBytes): a clipboard image is one ~10 M-char line. */
        const val AFTER_AUTH = 64 * 1024 * 1024
    }
}
