package com.swiftgreen.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.io.File
import java.nio.file.Files

/** The path guard is the only thing between a wire string and the rest of the disk. */
class MediaBrowserStoreTest {

    private val root: File = Files.createTempDirectory("sg-root").toFile().canonicalFile

    @Test
    fun resolvesPathsInsideRoot() {
        assertEquals(root, MediaBrowserStore.resolve(root, ""))
        assertEquals(File(root, "DCIM/Camera"), MediaBrowserStore.resolve(root, "DCIM/Camera"))
        assertEquals(File(root, "Download"), MediaBrowserStore.resolve(root, "DCIM/../Download"))
    }

    @Test
    fun refusesPathsThatEscapeRoot() {
        assertNull(MediaBrowserStore.resolve(root, ".."))
        assertNull(MediaBrowserStore.resolve(root, "../../data/data"))
        assertNull(MediaBrowserStore.resolve(root, "DCIM/../../etc"))
        // Sibling sharing the root's name as a prefix must not pass a naive startsWith.
        assertNull(MediaBrowserStore.resolve(root, "../${root.name}-evil"))
    }

    @Test
    fun searchFindsNamesAnywhereButSkipsHiddenAndAndroidData() {
        File(root, "DCIM/Camera").mkdirs()
        File(root, "DCIM/Camera/Trip-Goa.jpg").writeText("x")
        File(root, "Download/goa tickets.pdf").apply { parentFile!!.mkdirs(); writeText("x") }   // always under root
        File(root, "Android/data/app/goa.cache").apply { parentFile!!.mkdirs(); writeText("x") }   // always under root
        File(root, ".hidden/goa.txt").apply { parentFile!!.mkdirs(); writeText("x") }   // always under root

        val names = MediaBrowserStore.searchIn(root, "GOA").map { it.name }.sorted()
        assertEquals(listOf("Trip-Goa.jpg", "goa tickets.pdf"), names)
        assertEquals(emptyList<File>(), MediaBrowserStore.searchIn(root, "g"))      // too short
        assertEquals(1, MediaBrowserStore.searchIn(root, "goa", limit = 1).size)
    }
}
