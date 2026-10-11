package com.swiftgreen.app

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ShareableSchemeTest {
    // Another app could hand the share target file:///data/data/com.swiftgreen.app/...,
    // which SwiftGreen opened with its own permissions and sent to the Mac.
    @Test
    fun onlyContentUrisAreShared() {
        assertTrue(isShareableScheme("content"))
        assertFalse(isShareableScheme("file"))
        assertFalse(isShareableScheme("FILE"))
        assertFalse(isShareableScheme("http"))
        assertFalse(isShareableScheme(null))
        assertFalse(isShareableScheme(""))
    }
}
