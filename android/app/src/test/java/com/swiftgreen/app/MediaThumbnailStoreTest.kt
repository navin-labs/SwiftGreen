package com.swiftgreen.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** The sample-size arithmetic is the one place this pass can OOM or ship a blurry tile. */
class MediaThumbnailStoreTest {

    @Test
    fun samplesDownLargePhotosButNeverBelowTarget() {
        // 12MP 4:3 — the common DCIM case.
        val sample = MediaThumbnailStore.inSampleSizeFor(4000, 3000, 200)
        assertEquals(8, sample)
        assertTrue("short edge must stay >= 200 so the crop never upscales",
            3000 / sample >= 200)
    }

    @Test
    fun neverSamplesBelowOne() {
        assertEquals(1, MediaThumbnailStore.inSampleSizeFor(150, 150, 200))
        assertEquals(1, MediaThumbnailStore.inSampleSizeFor(200, 200, 200))
        // Degenerate bounds from a corrupt header must not spin the while loop.
        assertEquals(1, MediaThumbnailStore.inSampleSizeFor(0, 0, 200))
    }

    @Test
    fun theNarrowEdgeGovernsOnPanoramas() {
        // 10000x400 panorama: sampling for the long edge would take the short edge to 25px.
        val sample = MediaThumbnailStore.inSampleSizeFor(10000, 400, 200)
        assertEquals(2, sample)
        assertTrue(400 / sample >= 200)
    }

    @Test
    fun isAlwaysAPowerOfTwo() {
        // BitmapFactory rounds non-powers down anyway; returning one directly keeps the
        // computed dimensions and the actual decode in agreement.
        for (w in listOf(640, 1920, 4032, 8000)) {
            val sample = MediaThumbnailStore.inSampleSizeFor(w, w, 200)
            assertEquals("sample $sample for ${w}px is not a power of two",
                0, sample and (sample - 1))
        }
    }
}
