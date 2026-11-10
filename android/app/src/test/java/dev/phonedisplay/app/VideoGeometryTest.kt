package dev.phonedisplay.app

import org.junit.Assert.assertEquals
import org.junit.Test

class VideoGeometryTest {

    @Test
    fun widePhoneCenterCropsA16By9Stream() {
        val scale = VideoGeometry.scale(1920, 1080, 3120, 1440)
        assertEquals(1.625f, scale, 1e-4f)
        assertEquals(0f, VideoGeometry.offsetX(1920, 3120, scale), 1e-4f)
        assertEquals(-157.5f, VideoGeometry.offsetY(1080, 1440, scale), 1e-4f)
        assertEquals(960f, VideoGeometry.toStreamX(1560f, 1920, 3120, scale), 1e-4f)
        assertEquals(540f, VideoGeometry.toStreamY(720f, 1080, 1440, scale), 1e-4f)
    }

    @Test
    fun matchingAspectNeedsNoCrop() {
        val scale = VideoGeometry.scale(3120, 1440, 3120, 1440)
        assertEquals(1f, scale, 1e-4f)
        assertEquals(0f, VideoGeometry.offsetX(3120, 3120, scale), 1e-4f)
        assertEquals(0f, VideoGeometry.offsetY(1440, 1440, scale), 1e-4f)
        assertEquals(1560f, VideoGeometry.toStreamX(1560f, 3120, 3120, scale), 1e-4f)
        assertEquals(720f, VideoGeometry.toStreamY(720f, 1440, 1440, scale), 1e-4f)
    }
}
