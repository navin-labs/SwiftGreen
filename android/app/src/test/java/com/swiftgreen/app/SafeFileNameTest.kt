package com.swiftgreen.app

import org.junit.Assert.assertEquals
import org.junit.Test

class SafeFileNameTest {
    @Test
    fun plainNamesPassThrough() {
        assertEquals("photo.jpg", safeFileName("photo.jpg"))
        assertEquals("my file (1).tar.gz", safeFileName("my file (1).tar.gz"))
    }

    @Test
    fun traversalKeepsOnlyTheLastComponent() {
        assertEquals("swiftgreen_pairing.xml",
            safeFileName("../../../../data/data/com.swiftgreen.app/shared_prefs/swiftgreen_pairing.xml"))
        assertEquals("x.plist", safeFileName("..\\..\\x.plist"))
        assertEquals("evil", safeFileName("/abs/path/evil"))
    }

    @Test
    fun nothingUsableIsEmpty() {
        assertEquals("", safeFileName(""))
        assertEquals("", safeFileName(".."))
        assertEquals("", safeFileName("a/.."))
        assertEquals("", safeFileName("dir/"))
    }
}
