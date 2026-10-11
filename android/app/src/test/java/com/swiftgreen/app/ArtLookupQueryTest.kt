package com.swiftgreen.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ArtLookupQueryTest {
    @Test fun stripsVideoNoise() {
        assertEquals("Teri Tasveer - Bayaan",
            MediaSessionManager.artLookupQuery("Teri Tasveer (Lyrics) -  Bayaan", "Stoner Melodies"))
        assertEquals("Kesariya Arijit Singh",
            MediaSessionManager.artLookupQuery("Kesariya [Official Video] | Brahmastra", "Arijit Singh"))
        assertNull(MediaSessionManager.artLookupQuery("", "x"))
    }

    @Test fun matchKeyIgnoresPunctuation() {
        assertEquals("teritasveer", MediaSessionManager.artMatchKey("Teri Tasveer!"))
    }
}
