package com.wqglass.transfer

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test
import java.io.File

class ProtocolUtilsTest {

    @Test
    fun safeResolvePath_blocksTraversalOutsideRoot() {
        val root = File(System.getProperty("java.io.tmpdir"), "wqglass_root_test").apply { mkdirs() }
        try {
            val child = ProtocolUtils.safeResolvePath(root, "movies/clip.mp4")
            assertNotNull(child)
            assertEquals(File(root, "movies/clip.mp4").canonicalFile, child)

            assertNull(ProtocolUtils.safeResolvePath(root, "../secret.txt"))
            assertNull(ProtocolUtils.safeResolvePath(root, "movies/../../etc/passwd"))
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun parseQueryParams_decodesKeysAndValues() {
        val parsed = ProtocolUtils.parseQueryParams("path=My%20Videos%2F2026&name=clip%201.mp4&pin=4829")
        assertEquals("My Videos/2026", parsed["path"])
        assertEquals("clip 1.mp4", parsed["name"])
        assertEquals("4829", parsed["pin"])
    }

    @Test
    fun parseQrPayload_extractsEndpointAndPin() {
        val parsed = ProtocolUtils.parseQrPayload("http://192.168.1.42:8765/?pin=4829")
        assertNotNull(parsed)
        assertEquals("192.168.1.42:8765", parsed?.endpoint)
        assertEquals("4829", parsed?.pin)

        val noPin = ProtocolUtils.parseQrPayload("http://10.0.0.5:8765")
        assertNotNull(noPin)
        assertEquals("10.0.0.5:8765", noPin?.endpoint)
        assertNull(noPin?.pin)
    }

    @Test
    fun resolveTreeDocIdToPath_mapsPrimaryAndSdCard() {
        assertEquals("/storage/emulated/0", ProtocolUtils.resolveTreeDocIdToPath("primary:"))
        assertEquals("/storage/emulated/0/DCIM/Camera", ProtocolUtils.resolveTreeDocIdToPath("primary:DCIM/Camera"))
        assertEquals("/storage/9C33-6BBD/Movies", ProtocolUtils.resolveTreeDocIdToPath("9C33-6BBD:Movies"))
        assertEquals("/storage/emulated/0/Documents/Work", ProtocolUtils.resolveTreeDocIdToPath("home:Work"))
    }

    @Test
    fun formatBytes_categories_andPlatformBadges() {
        assertEquals("512 B", ProtocolUtils.formatBytes(512))
        assertEquals("2.0 KB", ProtocolUtils.formatBytes(2048))
        assertEquals("1.00 MB", ProtocolUtils.formatBytes(1024L * 1024L))
        assertEquals("Videos", ProtocolUtils.categorizeFileName("movie.mp4"))
        assertEquals("Photos", ProtocolUtils.categorizeFileName("IMG_001.HEIC"))
        assertEquals("Archives", ProtocolUtils.categorizeFileName("app.apk"))

        val win = DiscoveredPeer(device = "DESKTOP-PC", platform = "windows", ip = "192.168.1.9", port = 8765)
        assertEquals("Windows", win.platformBadge)

        val ios = DiscoveredPeer(device = "iPhone", platform = "", ip = "192.168.1.10", port = 8765)
        assertEquals("iOS", ios.platformBadge)

        val android = DiscoveredPeer(device = "Pixel 9", platform = "android", ip = "192.168.1.11", port = 8765)
        assertEquals("Android", android.platformBadge)
    }
}
